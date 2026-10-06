# Architecture Views

**Purpose:** Document the `docs/design/architecture-views/` collection scope, ownership, and maintenance rules.
**Last updated:** 2026-10-02

Architecture Views are design-only review documents. They may show vertical flows, dependency paths, and cross-layer movement, but they must not become runtime implementation roots.

`system-architecture.json` is the source for the current/target/gap process model. Do not hand-edit
the generated Mermaid block in `../Vityo-System-Architecture.md` or the standalone HTML view.
Generate both outputs with:

```bash
python3 scripts/vityo_architecture.py --write
```

The non-mutating CI check validates source anchors, import/dependency direction, and generated
output drift:

```bash
python3 scripts/vityo_architecture.py --check
```

For a localhost-only viewer that refreshes when the model changes, run
`python3 scripts/vityo_architecture.py --serve --watch`. It binds only to `127.0.0.1` and serves
the architecture page and model JSON at fixed paths. `--fragment` writes the same model as a
self-contained, theme-aware HTML fragment without a document wrapper or network calls. The model
and generated diagrams show declared architecture facts; they do not prove runtime behavior.

Concrete implementation directories must stay under horizontal architecture directories such as `appearance/`, `interaction/`, `service/`, and `environment/`.
