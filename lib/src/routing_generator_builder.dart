import 'dart:async';
import 'dart:collection';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart';
import 'package:routing_generator/routing_generator.dart';
import 'package:routing_generator_builder/src/routing.dart';
import 'package:source_gen/source_gen.dart';

final class RoutingGeneratorBuilder extends Builder {
  final _allFiles = Glob('**/**.dart');

  static const routingChecker = TypeChecker.fromRuntime(RoutingGenerator);

  @override
  Map<String, List<String>> get buildExtensions => {
    r'$lib$': ['routing/routing.dart'],
  };

  static Iterable<Routing> buildRouteTree(List<Routing> routes) {
    Routing? rootRoute;
    final Set<String> uniquePaths = {};
    final Set<String?> uniqueNames = {};
    final List<Routing> topLevelRoutes = [];
    final List<Routing> childRoutes = [];

    // Single pass to validate uniqueness & categorize routes (O(n))
    for (final route in routes) {
      // Ensure unique paths
      if (!uniquePaths.add(route.path.path)) {
        throw UnsupportedError('The "path" must be unique for every page');
      }

      // Ensure unique names (if present)
      if (route.name != null && !uniqueNames.add(route.name)) {
        throw UnsupportedError('The "name" must be unique for every page');
      }

      // Identify root route
      if (route.path.path == '/') {
        rootRoute = route;
      }

      // Categorize into top-level or child routes
      if (route.path.pathSegments.length == 1) {
        topLevelRoutes.add(route);
      } else if (route.path.pathSegments.length >= 2) {
        childRoutes.add(route);
      }
    }

    // Ensure there is at least one top-level route
    if (rootRoute == null && topLevelRoutes.isEmpty) {
      throw UnsupportedError(
        'The application must have at least one top-level route',
      );
    }

    // Attach top-level routes to the root if it exists
    if (rootRoute != null) {
      for (final route in topLevelRoutes) {
        rootRoute.addChild(route);
      }
    }

    // Build the hierarchy in O(n) using optimized `buildRouteHierarchy`
    if (childRoutes.isNotEmpty) {
      buildRouteHierarchy(topLevelRoutes, childRoutes);
    }

    // Return either the root route or the top-level routes
    return rootRoute != null ? [rootRoute] : topLevelRoutes;
  }

  static void buildRouteHierarchy(
      Iterable<Routing> parentRoutes,
      Iterable<Routing> childRoutes,
      ) {
    final Queue<(Routing, List<Routing>, int)> queue = Queue();

    // Initialize queue with current parent routes
    for (final parent in parentRoutes) {
      queue.add((parent, childRoutes.toList(), 1));
    }

    while (queue.isNotEmpty) {
      final (Routing, List<Routing>, int) current = queue.removeFirst();
      final Routing parent = current.$1;
      final List<Routing> children = current.$2;
      final int currentDepth = current.$3;

      final int index = currentDepth - 1;
      final Map<String, List<Routing>> childMap = {};

      final List<Routing> nextLevelChildren = [];

      // Group child routes by their segment at the current depth
      for (final child in children) {
        if (child.path.pathSegments.length > index) {
          final String segmentKey = child.path.pathSegments[index];
          childMap.putIfAbsent(segmentKey, () => []).add(child);
          nextLevelChildren.add(child);
        }
      }

      if (parent.path.pathSegments.length - 1 > index) {
        queue.add((parent, nextLevelChildren, currentDepth + 1));
        continue;
      }

      final String parentSegment = parent.path.pathSegments[index];

      if (childMap.containsKey(parentSegment)) {
        for (final child in childMap[parentSegment]!) {
          if (child == parent) {
            continue;
          }

          child.skip = currentDepth;
          parent.addChild(child);
          queue.add((child, nextLevelChildren, currentDepth + 1));
        }
      }
    }
  }

  static void buildRouteConfig(
      StringBuffer routeBuffer,
      Iterable<Routing> routeHierarchy,
      ) {
    for (final route in routeHierarchy) {
      final String routePath = route.path.pathSegments.skip(route.skip).join("/");
      final String? routeName = route.name;
      final String routePage = route.page;
      final List<Routing> childRoutes = route.children;
      final String isConstant = route.isConst;

      // Use a single write call for better performance
      routeBuffer.write("GoRoute(path: '/$routePath'");

      if (routeName != null) {
        routeBuffer.write(", name: '$routeName'");
      }

      routeBuffer.write(", builder: (_,_) =>$isConstant $routePage()");

      // Process child routes efficiently
      if (childRoutes.isNotEmpty) {
        routeBuffer.write(', routes: [');

        // Reduce recursive calls by using a loop instead of multiple writes
        buildRouteConfig(routeBuffer, childRoutes);

        routeBuffer.write(']');
      }

      routeBuffer.write('),');
    }
  }


  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final importDirectives = <Directive>[
      Directive(
        (builder) =>
            builder
              ..type = DirectiveType.import
              ..url = 'package:go_router/go_router.dart',
      ),
    ];
    final routeBuffer = StringBuffer('[');
    final routeClasses = <Routing>[];

    // Iterate over assets in a single pass (O(n))
    await for (final asset in buildStep.findAssets(_allFiles)) {
      // Skip if not a library
      if (!await buildStep.resolver.isLibrary(asset)) continue;

      final libraryReader = LibraryReader(
        await buildStep.resolver.libraryFor(asset),
      );
      final annotatedElements = libraryReader.annotatedWith(
        routingChecker,
        throwOnUnresolved: false,
      );

      // Skip assets without annotations
      if (annotatedElements.isEmpty) continue;

      // Add import directive only if annotations exist
      importDirectives.add(
        Directive(
          (builder) =>
              builder
                ..type = DirectiveType.import
                ..url =
                    'package:${asset.package}/${asset.pathSegments.skip(1).join('/')}',
        ),
      );

      // Process annotated elements in a single pass (O(m))
      for (final element in annotatedElements) {
        final routingInstance = Routing(
          object: element.annotation.objectValue,
          page: element.element.displayName,
          isConst: switch (element.element) {
            ClassElement(unnamedConstructor: final constructor) =>
              constructor?.isConst == true ? ' const' : '',
            _ =>
              throw UnsupportedError(
                '${element.element.name}: Must be a class',
              ),
          },
        );
        routeClasses.add(routingInstance);
      }
    }

    // If no routes found, exit early
    if (routeClasses.isEmpty) return;

    // Build route hierarchy in O(n)
    final routeHierarchy = buildRouteTree(routeClasses);

    // Generate routing in O(n)
    buildRouteConfig(routeBuffer, routeHierarchy);

    routeBuffer.write(']');

    final generatedLibrary = Library(
      (builder) =>
          builder
            ..directives.addAll(importDirectives)
            ..body.add(
              Class(
                (builder) =>
                    builder
                      ..name = 'Routing'
                      ..modifier = ClassModifier.final$
                      ..abstract = true
                      ..methods.add(
                        Method(
                          (builder) =>
                              builder
                                ..name = 'routes'
                                ..returns = refer('List<GoRoute>')
                                ..lambda = true
                                ..static = true
                                ..body = Code('$routeBuffer'),
                        ),
                      ),
              ),
            ),
    );

    final outputFile = AssetId(
      buildStep.inputId.package,
      join('lib', 'routing', 'routing.dart'),
    );

    // Write output file efficiently (O(1))
    return buildStep.writeAsString(
      outputFile,
      DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
      ).format('${generatedLibrary.accept(DartEmitter.scoped())}'),
    );
  }
}
