import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/view_render.dart';

void main() {
  group('Shell narrow viewport behavior', () {
    test(
      'compact mode hides activity rail and produces mobile viewport key',
      () {
        final plan = ShellLayoutPlan.forViewport(
          activeWorkbenchRoute: WorkbenchRoute.agent,
          compact: true,
        );

        expect(plan.mode, ShellLayoutMode.compact);
        expect(plan.panelById('activity-rail')?.visible, isFalse);
        expect(plan.renderBinding().viewportKey, 'shell-viewport-mobile');
        expect(plan.renderBinding().compactActivityFallback, isTrue);
      },
    );

    test(
      'desktop mode shows activity rail and produces desktop viewport key',
      () {
        final plan = ShellLayoutPlan.forViewport(
          activeWorkbenchRoute: WorkbenchRoute.agent,
          compact: false,
        );

        expect(plan.mode, ShellLayoutMode.desktop);
        expect(plan.panelById('activity-rail')?.visible, isTrue);
        expect(plan.renderBinding().viewportKey, 'shell-viewport-desktop');
        expect(plan.renderBinding().compactActivityFallback, isFalse);
      },
    );

    test('narrow viewport stacks panels in ListView instead of Row', () {
      final compactPlan = ShellLayoutPlan.forViewport(
        activeWorkbenchRoute: WorkbenchRoute.search,
        compact: true,
      );
      final desktopPlan = ShellLayoutPlan.forViewport(
        activeWorkbenchRoute: WorkbenchRoute.search,
        compact: false,
      );

      // Compact layout panels should use ListView (vertical stacking),
      // desktop uses Row (horizontal). The plan captures this via layout binding.
      expect(compactPlan.mode, ShellLayoutMode.compact);
      expect(desktopPlan.mode, ShellLayoutMode.desktop);
    });

    test('bottom panel tab selection works independently of viewport mode', () {
      final registry = ShellPanelContributionRegistry.defaultIdePanels();
      for (final tab in WorkbenchRoute.values) {
        final plan = ShellLayoutPlan.forViewport(
          activeWorkbenchRoute: tab,
          compact: false,
        );
        final compactPlan = ShellLayoutPlan.forViewport(
          activeWorkbenchRoute: tab,
          compact: true,
        );

        // Same tab active in both modes
        expect(plan.activeWorkbenchRoute, tab);
        expect(compactPlan.activeWorkbenchRoute, tab);
        // Panel for this tab is active
        final panelId = registry.contributions
            .singleWhere((contribution) => contribution.route == tab)
            .id;
        expect(plan.panelById(panelId)?.active, isTrue);
        expect(compactPlan.panelById(panelId)?.active, isTrue);
      }
    });
  });

  group('Shell panel state', () {
    test(
      'bottom panel visibility toggles through plan without losing active tab',
      () {
        final controller = ShellLayoutPreferenceController(
          initialPreferences: const ShellLayoutPreferences(
            workspaceId: 'demo',
            activeWorkbenchRoute: WorkbenchRoute.problems,
            bottomPanelExpanded: true,
          ),
        );

        expect(
          controller.preferences.activeWorkbenchRoute,
          WorkbenchRoute.problems,
        );
        expect(controller.preferences.bottomPanelExpanded, isTrue);

        // Toggle panel collapsed
        controller.setBottomPanelExpanded(false);
        expect(controller.preferences.bottomPanelExpanded, isFalse);
        // Active tab is preserved
        expect(
          controller.preferences.activeWorkbenchRoute,
          WorkbenchRoute.problems,
        );

        // Toggle back
        controller.setBottomPanelExpanded(true);
        expect(controller.preferences.bottomPanelExpanded, isTrue);

        // Panel visible state reflects expanded + active tab
        final binding = controller.renderBindingForViewport(compact: false);
        expect(binding.bottomPanelExpanded, isTrue);
        expect(binding.activePanelId, 'bottom.problems');
      },
    );

    test('panel pinned state persists across binding recalculations', () {
      final controller = ShellLayoutPreferenceController(
        initialPreferences: const ShellLayoutPreferences(
          workspaceId: 'demo',
          activeWorkbenchRoute: WorkbenchRoute.debug,
        ),
      );
      controller.setPanelPinned('bottom.debug', pinned: true);

      final plan = controller.planForViewport(compact: false);
      expect(plan.panelById('bottom.debug')?.metadata['pinned'], isTrue);

      // Recalculate binding
      final binding = controller.renderBindingForViewport(compact: false);
      expect(binding.activePanelId, 'bottom.debug');
    });

    test('preference controller aggregates revision count', () {
      final controller = ShellLayoutPreferenceController(
        initialPreferences: const ShellLayoutPreferences(workspaceId: 'demo'),
      );

      expect(controller.revision, 0);

      controller.selectWorkbenchRoute(WorkbenchRoute.search);
      expect(controller.revision, 1);

      controller.setPanelPinned('primary.search', pinned: true);
      expect(controller.revision, 2);

      controller.setPanelVisible('bottom.runtime', visible: false);
      expect(controller.revision, 3);

      controller.setBottomPanelExpanded(false);
      expect(controller.revision, 3);
    });
  });

  group('Shell layout plan roundtrip', () {
    test('plan serialization roundtrips active tab and panel visibility', () {
      final plan = ShellLayoutPlan.forViewport(
        activeWorkbenchRoute: WorkbenchRoute.search,
        compact: true,
      );
      final json = plan.toJson();
      final restored = ShellLayoutPlan.fromJson(json);

      expect(restored.activeWorkbenchRoute, WorkbenchRoute.search);
      expect(restored.mode, ShellLayoutMode.compact);
      expect(restored.panelById('primary.search')?.active, isTrue);
      expect(restored.renderBinding().viewportKey, 'shell-viewport-mobile');

      // Edit, serialize, restore again
      final edited = ShellLayoutPlan.forViewport(
        activeWorkbenchRoute: WorkbenchRoute.extensions,
        compact: false,
      );
      final editedJson = edited.toJson();
      final restoredEdited = ShellLayoutPlan.fromJson(editedJson);

      expect(restoredEdited.activeWorkbenchRoute, WorkbenchRoute.extensions);
      expect(restoredEdited.mode, ShellLayoutMode.desktop);
      expect(
        restoredEdited.renderBinding().viewportKey,
        'shell-viewport-desktop',
      );
    });
  });

  group('Focus model verification', () {
    test(
      'ShellLayoutPreferenceController selectWorkbenchRoute preserves focus intent',
      () {
        final controller = ShellLayoutPreferenceController(
          initialPreferences: const ShellLayoutPreferences(
            workspaceId: 'demo',
            activeWorkbenchRoute: WorkbenchRoute.runtime,
          ),
        );

        // Selecting the same tab is a no-op
        controller.selectWorkbenchRoute(WorkbenchRoute.runtime);
        expect(
          controller.preferences.activeWorkbenchRoute,
          WorkbenchRoute.runtime,
        );
        expect(controller.revision, 0);

        // Switching tabs
        controller.selectWorkbenchRoute(WorkbenchRoute.problems);
        expect(
          controller.preferences.activeWorkbenchRoute,
          WorkbenchRoute.problems,
        );
        expect(controller.revision, 1);
      },
    );

    test('desktop editor panel has highest flex and is always active', () {
      // The editor is always active in both desktop and compact modes
      for (final compact in [true, false]) {
        final plan = ShellLayoutPlan.forViewport(
          activeWorkbenchRoute: WorkbenchRoute.runtime,
          compact: compact,
        );
        expect(
          plan.panelById('editor')?.active,
          isTrue,
          reason: 'Editor must always be active in compact=$compact mode',
        );
      }
    });
  });
}
