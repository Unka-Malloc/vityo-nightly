# View Render Boundary

`view_render` is the presentation boundary.

This layer owns Flutter widgets, shell layout, visual surfaces, responsive
composition, theme application, and user interaction presentation. It may depend
on `view_ide`, but `view_ide` must not depend on this layer.

Rules:

1. Flutter widget imports belong here.
2. Render code may present state from `view_ide`, but must not implement
   compiler, package-manager, registry, hosted-control-plane, or execution
   semantics directly.
3. Buttons, cards, panels, responsive layout, theme tokens, and visual feedback
   belong here.
4. Business state must be requested through typed IDE models, commands, and
   capability snapshots rather than guessed from paths or UI conditions.

Current status:

Render internals are split into:

1. `shell/`: `ShellModel` bottom-tab presentation state, `ShellScope`, `VityoShellScaffold`, shortcut binding, bottom surface selection, responsive shell layout, and shell panels.
2. `editor/`: Flutter editor surface, source preview, language inspector presentation, keyboard/mouse interaction widgets, and inline feedback rendering.
3. `runtime/`: runtime and debug console surfaces, replay visualization, lane cards, runtime-event presentation, and render-only accent mapping.
4. `agent/`: agent provider/module presentation and adapter-route display.
5. `theme/`: Flutter `ThemeData` and theme override presentation objects.
6. `platform/`: viewport profile and responsive render-family selection.

The editor render library keeps `editor_surface.dart` as its public library
root and separates implementation by responsibility: `editor_surface_shell`
owns composition and document chrome, `editor_source_pane` owns input and
source interactions, `editor_language_inspector` owns language presentation,
and `editor_render_pipeline` owns viewport-bounded line painting and semantics.
The smoke entrypoint mirrors those boundaries through the focused registration
files under `test/smoke/` while preserving one canonical test command.

Runtime command execution and workflow state are inherited from `view_ide/shell_runtime`.

Move widgets here incrementally after each move preserves the one-way dependency:

```text
view_render -> view_ide
view_ide    -> no view_render
```
