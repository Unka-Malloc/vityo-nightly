#!/usr/bin/env python3
"""Generate Vityo architecture views from the repository-owned JSON model."""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import threading
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = Path("docs/design/architecture-views/system-architecture.json")
MARKDOWN_PATH = Path("docs/design/Vityo-System-Architecture.md")
HTML_PATH = Path("docs/design/architecture-views/system-architecture.html")
MARKDOWN_START = "<!-- VITYO_ARCHITECTURE:START -->"
MARKDOWN_END = "<!-- VITYO_ARCHITECTURE:END -->"
ALLOWED_STATUSES = {"current", "target", "gap"}
_DART_IMPORT = re.compile(r"\b(?:import|export|part)\s+['\"]([^'\"]+)['\"]")
_PUB_SECTION = re.compile(r"^(dependencies|dev_dependencies|dependency_overrides):\s*(?:#.*)?$")
_PUB_ITEM = re.compile(r"^\s{2}([A-Za-z0-9_.-]+):(?:\s|$)")
_PACKAGE_VALUE = re.compile(r"^\s{4}package:\s*([A-Za-z0-9_.-]+)\s*$")
_CARGO_DEPENDENCY_TABLES = {"dependencies", "dev-dependencies", "build-dependencies"}


class ArchitectureError(ValueError):
    """An invalid model, missing anchor, or violated dependency boundary."""


def _safe_repo_path(root: Path, value: str) -> Path:
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or ".." in candidate.parts or not candidate.parts:
        raise ArchitectureError(f"unsafe repository path in model: {value!r}")
    resolved = (root / Path(*candidate.parts)).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as error:
        raise ArchitectureError(f"repository path escapes checkout: {value!r}") from error
    return resolved


def load_model(root: Path = REPOSITORY_ROOT) -> dict[str, object]:
    path = _safe_repo_path(root, MODEL_PATH.as_posix())
    try:
        model = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ArchitectureError(f"cannot read architecture model: {MODEL_PATH}") from error
    if not isinstance(model, dict):
        raise ArchitectureError("architecture model root must be an object")
    validate_model(root, model)
    return model


def _required_string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ArchitectureError(f"{context} must be a non-empty string")
    return value


def validate_model(root: Path, model: dict[str, object]) -> None:
    root = root.resolve()
    if model.get("schemaVersion") != 1:
        raise ArchitectureError("unsupported architecture model schemaVersion")
    _required_string(model.get("title"), "title")
    _required_string(model.get("subtitle"), "subtitle")

    lanes = model.get("lanes")
    nodes = model.get("nodes")
    edges = model.get("edges")
    anchors = model.get("sourceAnchors")
    boundaries = model.get("dependencyBoundaries")
    if not all(isinstance(value, list) for value in (lanes, nodes, edges, anchors, boundaries)):
        raise ArchitectureError("lanes, nodes, edges, sourceAnchors, and dependencyBoundaries must be arrays")

    lane_ids = _unique_ids(lanes, "lane")
    node_ids = _unique_ids(nodes, "node")
    anchor_ids = _unique_ids(anchors, "source anchor")
    _unique_ids(edges, "edge")
    _unique_ids(boundaries, "dependency boundary")

    for lane in lanes:
        _required_string(lane.get("title"), f"lane {lane['id']} title")
        _required_string(lane.get("description"), f"lane {lane['id']} description")

    for node in nodes:
        if node.get("lane") not in lane_ids:
            raise ArchitectureError(f"node {node['id']} references an unknown lane")
        if node.get("status") not in ALLOWED_STATUSES:
            raise ArchitectureError(f"node {node['id']} has an unsupported status")
        for field in ("label", "summary", "detail"):
            _required_string(node.get(field), f"node {node['id']} {field}")
        sources = node.get("sources", [])
        if not isinstance(sources, list) or any(source not in anchor_ids for source in sources):
            raise ArchitectureError(f"node {node['id']} references an unknown source anchor")

    for edge in edges:
        if edge.get("from") not in node_ids or edge.get("to") not in node_ids:
            raise ArchitectureError(f"edge {edge['id']} references an unknown node")
        if edge.get("status") not in ALLOWED_STATUSES:
            raise ArchitectureError(f"edge {edge['id']} has an unsupported status")
        if "overview" in edge and not isinstance(edge["overview"], bool):
            raise ArchitectureError(f"edge {edge['id']} overview must be a boolean")
        _required_string(edge.get("label"), f"edge {edge['id']} label")

    for anchor in anchors:
        source_path = _required_string(anchor.get("path"), f"anchor {anchor['id']} path")
        path = _safe_repo_path(root, source_path)
        if not path.is_file():
            raise ArchitectureError(f"source anchor file is missing: {source_path}")
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise ArchitectureError(f"cannot read source anchor: {source_path}") from error
        required = anchor.get("contains")
        if not isinstance(required, list) or not required:
            raise ArchitectureError(f"anchor {anchor['id']} must name at least one source token")
        for snippet in required:
            _required_string(snippet, f"anchor {anchor['id']} token")
            if snippet not in source:
                raise ArchitectureError(f"source anchor changed: {source_path} is missing {snippet!r}")

    for boundary in boundaries:
        for field in ("kind",):
            _required_string(boundary.get(field), f"dependency boundary {boundary['id']} {field}")
        list_fields = {
            "dart-imports": ("roots", "forbiddenPackages", "forbiddenRelativeRoots"),
            "pub-dependencies": ("manifests", "forbiddenPackages"),
            "cargo-dependencies": ("manifests", "forbiddenPackages"),
        }.get(boundary["kind"])
        if list_fields is None:
            raise ArchitectureError(f"unknown dependency boundary kind: {boundary['kind']!r}")
        for field in list_fields:
            values = boundary.get(field)
            if not isinstance(values, list) or any(
                not isinstance(item, str) or not item.strip() for item in values
            ):
                raise ArchitectureError(
                    f"dependency boundary {boundary['id']} {field} must be an array of non-empty strings"
                )
        if boundary["kind"] == "dart-imports" and "optionalRoots" in boundary and not isinstance(
            boundary["optionalRoots"], bool
        ):
            raise ArchitectureError(
                f"dependency boundary {boundary['id']} optionalRoots must be a boolean"
            )
        kind = boundary.get("kind")
        if kind == "dart-imports":
            _check_dart_import_boundary(root, boundary)
        elif kind == "pub-dependencies":
            _check_pub_dependencies(root, boundary)
        elif kind == "cargo-dependencies":
            _check_cargo_dependencies(root, boundary)


def _unique_ids(values: list[object], kind: str) -> set[str]:
    identifiers: set[str] = set()
    for value in values:
        if not isinstance(value, dict):
            raise ArchitectureError(f"each {kind} must be an object")
        identifier = _required_string(value.get("id"), f"{kind} id")
        if not re.fullmatch(r"[a-z][a-z0-9_-]*", identifier):
            raise ArchitectureError(f"invalid {kind} id: {identifier!r}")
        if identifier in identifiers:
            raise ArchitectureError(f"duplicate {kind} id: {identifier}")
        identifiers.add(identifier)
    return identifiers


def _check_dart_import_boundary(root: Path, boundary: dict[str, object]) -> None:
    forbidden_packages = set(boundary.get("forbiddenPackages", []))
    forbidden_roots = [
        _safe_repo_path(root, item).resolve()
        for item in boundary.get("forbiddenRelativeRoots", [])
    ]
    for root_name in boundary.get("roots", []):
        source_root = _safe_repo_path(root, root_name)
        if not source_root.exists() and boundary.get("optionalRoots") is True:
            continue
        if not source_root.is_dir():
            raise ArchitectureError(f"dependency boundary {boundary['id']} root is missing: {root_name}")
        for path in source_root.rglob("*.dart"):
            if path.is_symlink() or any(part.startswith(".") for part in path.relative_to(source_root).parts):
                continue
            try:
                source = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as error:
                raise ArchitectureError(f"cannot scan Dart dependency source: {path.relative_to(root)}") from error
            for import_uri in _DART_IMPORT.findall(source):
                if import_uri.startswith("package:"):
                    package_name = import_uri[len("package:"):].split("/", maxsplit=1)[0]
                    if package_name in forbidden_packages:
                        relative = path.relative_to(root).as_posix()
                        raise ArchitectureError(
                            f"dependency boundary {boundary['id']} violated by {relative}: {import_uri}"
                        )
                elif import_uri.startswith("."):
                    destination = (path.parent / import_uri).resolve()
                    if any(_is_relative_to(destination, forbidden_root) for forbidden_root in forbidden_roots):
                        relative = path.relative_to(root).as_posix()
                        raise ArchitectureError(
                            f"dependency boundary {boundary['id']} violated by relative import in {relative}"
                        )


def _is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _pub_dependency_names(text: str) -> set[str]:
    names: set[str] = set()
    in_dependencies = False
    current_dependency: str | None = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith((" ", "\t")):
            in_dependencies = _PUB_SECTION.match(line) is not None
            current_dependency = None
            continue
        if not in_dependencies:
            continue
        item = _PUB_ITEM.match(line)
        if item:
            current_dependency = item.group(1)
            names.add(current_dependency)
            continue
        package = _PACKAGE_VALUE.match(line)
        if package and current_dependency is not None:
            names.add(package.group(1))
    return names


def _check_pub_dependencies(root: Path, boundary: dict[str, object]) -> None:
    forbidden = set(boundary.get("forbiddenPackages", []))
    for manifest_name in boundary.get("manifests", []):
        manifest_path = _safe_repo_path(root, manifest_name)
        if not manifest_path.is_file():
            raise ArchitectureError(f"dependency manifest is missing: {manifest_name}")
        names = _pub_dependency_names(manifest_path.read_text(encoding="utf-8"))
        found = sorted(names & forbidden)
        if found:
            raise ArchitectureError(
                f"dependency boundary {boundary['id']} violated by {manifest_name}: {', '.join(found)}"
            )


def _cargo_dependency_names(value: object, names: set[str]) -> None:
    if not isinstance(value, dict):
        return
    for key, child in value.items():
        if key in _CARGO_DEPENDENCY_TABLES and isinstance(child, dict):
            for dependency, specification in child.items():
                names.add(dependency.replace("-", "_"))
                if isinstance(specification, dict) and isinstance(specification.get("package"), str):
                    names.add(specification["package"].replace("-", "_"))
        _cargo_dependency_names(child, names)


def _check_cargo_dependencies(root: Path, boundary: dict[str, object]) -> None:
    forbidden = {item.replace("-", "_") for item in boundary.get("forbiddenPackages", [])}
    for manifest_name in boundary.get("manifests", []):
        manifest_path = _safe_repo_path(root, manifest_name)
        if not manifest_path.is_file():
            raise ArchitectureError(f"Cargo manifest is missing: {manifest_name}")
        try:
            manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as error:
            raise ArchitectureError(f"cannot parse Cargo manifest: {manifest_name}") from error
        dependencies: set[str] = set()
        _cargo_dependency_names(manifest, dependencies)
        found = sorted(dependencies & forbidden)
        if found:
            raise ArchitectureError(
                f"dependency boundary {boundary['id']} violated by {manifest_name}: {', '.join(found)}"
            )


def render_mermaid(model: dict[str, object]) -> str:
    lines = ["flowchart LR"]
    for lane in model["lanes"]:
        lines.append(f"  subgraph {lane['id']}[\"{_mermaid_text(lane['title'])}\"]")
        lines.append("    direction TB")
        for node in model["nodes"]:
            if node["lane"] == lane["id"]:
                status = node["status"].upper()
                label = _mermaid_text(f"{node['label']} · {status}")
                lines.append(f"    {node['id']}[\"{label}\"]")
        lines.append("  end")
    for edge in model["edges"]:
        label = str(edge["label"])
        if edge["status"] != "current":
            label = f"{label} · {edge['status'].upper()}"
        lines.append(f"  {edge['from']} -->|\"{_mermaid_text(label)}\"| {edge['to']}")
    return "\n".join(lines)


def _mermaid_text(value: str) -> str:
    return value.replace('"', "'").replace("\n", " ").replace("<", "&lt;").replace(">", "&gt;")


def render_markdown(model: dict[str, object], existing: str) -> str:
    if existing.count(MARKDOWN_START) != 1 or existing.count(MARKDOWN_END) != 1:
        raise ArchitectureError("system architecture Markdown must contain one generated diagram marker pair")
    start = existing.index(MARKDOWN_START)
    end = existing.index(MARKDOWN_END)
    if end < start:
        raise ArchitectureError("system architecture generated diagram markers are reversed")
    block = (
        f"{MARKDOWN_START}\n"
        "Generated from [`system-architecture.json`](./architecture-views/system-architecture.json).\n\n"
        f"```mermaid\n{render_mermaid(model)}\n```\n"
        f"{MARKDOWN_END}"
    )
    return existing[:start] + block + existing[end + len(MARKDOWN_END):]


def render_fragment(model: dict[str, object]) -> str:
    lanes_html: list[str] = []
    nodes_by_id = {node["id"]: node for node in model["nodes"]}
    lane_positions = {lane["id"]: index for index, lane in enumerate(model["lanes"])}
    relations_by_node: dict[str, list[str]] = {node_id: [] for node_id in nodes_by_id}
    for edge in model["edges"]:
        source = nodes_by_id[edge["from"]]["label"]
        destination = nodes_by_id[edge["to"]]["label"]
        status = html.escape(edge["status"])
        relation = html.escape(edge["label"])
        relations_by_node[edge["from"]].append(
            f'<li><span>To {html.escape(destination)}</span> <span class="vya-muted">· {relation}</span> '
            f'<span class="vya-status" data-status="{status}">{status.title()}</span></li>'
        )
        relations_by_node[edge["to"]].append(
            f'<li><span>From {html.escape(source)}</span> <span class="vya-muted">· {relation}</span> '
            f'<span class="vya-status" data-status="{status}">{status.title()}</span></li>'
        )

    for lane in model["lanes"]:
        cards = []
        for node in model["nodes"]:
            if node["lane"] != lane["id"]:
                continue
            status = node["status"]
            sources = [anchor for anchor in model["sourceAnchors"] if anchor["id"] in node["sources"]]
            source_markup = "".join(
                f"<li><code>{html.escape(source['path'])}</code></li>" for source in sources
            )
            cards.append(
                f'<details class="vya-node" id="vya-node-{html.escape(node["id"])}" '
                f'data-node-id="{html.escape(node["id"])}" '
                f'data-lane-id="{html.escape(node["lane"])}" data-status="{html.escape(status)}">'
                '<summary class="vya-node-summary">'
                f'<span class="vya-status" data-status="{html.escape(status)}">{html.escape(status.title())}</span>'
                f'<span class="vya-node-title">{html.escape(node["label"])}</span>'
                '</summary><div class="vya-node-detail">'
                f'<p class="vya-node-caption">{html.escape(node["summary"])}</p>'
                f'<p>{html.escape(node["detail"])}</p>'
                '<h4>Connected operations</h4>'
                f'<ul>{"".join(relations_by_node[node["id"]])}</ul>'
                '<h4>Source anchors</h4>'
                f'<ul>{source_markup}</ul></div></details>'
            )
        lanes_html.append(
            f'<section class="vya-lane" data-lane-id="{html.escape(lane["id"])}" '
            f'aria-label="{html.escape(lane["title"] + ": " + lane["description"])}" '
            f'aria-labelledby="vya-lane-{html.escape(lane["id"])}">'
            f'<h2 id="vya-lane-{html.escape(lane["id"])}">{html.escape(lane["title"])}</h2>'
            f'<div class="vya-nodes">{"".join(cards)}</div></section>'
        )

    edges_json = json.dumps(
        [
            {
                "from": edge["from"],
                "to": edge["to"],
                "label": edge["label"],
                "status": edge["status"],
                "laneDistance": abs(
                    lane_positions[nodes_by_id[edge["from"]]["lane"]]
                    - lane_positions[nodes_by_id[edge["to"]]["lane"]]
                ),
            }
            for edge in model["edges"]
            if edge.get("overview", True)
        ],
        ensure_ascii=True,
        separators=(",", ":"),
    ).replace("</", "<\\/")

    return (
        '<section id="vityo-system-architecture" class="vya-root" '
        'aria-labelledby="vya-title">'
        '<style>' + _fragment_css() + '</style>'
        '<header class="vya-header">'
        f'<h1 id="vya-title">{html.escape(model["title"])}</h1>'
        f'<p>{html.escape(model["subtitle"])}</p>'
        '<ul class="vya-legend" aria-label="Implementation status">'
        '<li><span class="vya-status" data-status="current">Current</span></li>'
        '<li><span class="vya-status" data-status="target">Target</span></li>'
        '<li><span class="vya-status" data-status="gap">Gap</span></li>'
        '</ul></header>'
        '<h2 id="vya-map-title">Directed process and data flow</h2>'
        '<p class="vya-muted">Arrows follow authorized operations and state; expand a node for its description, connected owners, and source anchors.</p>'
        '<div class="vya-map" data-vya-map role="group" aria-labelledby="vya-map-title">'
        '<svg class="vya-edges" data-vya-edges aria-hidden="true" focusable="false">'
        '<defs>'
        '<marker id="vya-arrow-current" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker>'
        '<marker id="vya-arrow-target" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker>'
        '<marker id="vya-arrow-gap" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker>'
        '</defs></svg>'
        f'<div class="vya-lanes">{"".join(lanes_html)}</div>'
        '</div>'
        '<script>(() => {'
        'const root = document.getElementById("vityo-system-architecture");'
        'if (!root) return;'
        'const map = root.querySelector("[data-vya-map]");'
        'const svg = root.querySelector("[data-vya-edges]");'
        f'const edges = {edges_json};'
        'const ns = "http://www.w3.org/2000/svg";'
        'const draw = () => {'
        'const width = Math.max(1, map.clientWidth);'
        'const height = Math.max(1, map.scrollHeight);'
        'svg.setAttribute("viewBox", `0 0 ${width} ${height}`);'
        'svg.setAttribute("width", String(width));'
        'svg.setAttribute("height", String(height));'
        'for (const child of Array.from(svg.children)) if (child.tagName !== "defs") child.remove();'
        'const bounds = map.getBoundingClientRect();'
        'const lanes = new Map(Array.from(map.querySelectorAll(".vya-lane")).map((lane, index) => [lane.dataset.laneId, {index, rect:lane.getBoundingClientRect()}]));'
        'const boxes = new Map(Array.from(map.querySelectorAll("[data-node-id]")).map(node => {'
        'const rect = node.getBoundingClientRect();'
        'return [node.dataset.nodeId, {element:node, lane:node.dataset.laneId, left:rect.left-bounds.left, right:rect.right-bounds.left, top:rect.top-bounds.top, bottom:rect.bottom-bounds.top, cx:(rect.left+rect.right)/2-bounds.left, cy:(rect.top+rect.bottom)/2-bounds.top}];'
        '}));'
        'edges.forEach((edge, index) => {'
        'const from = boxes.get(edge.from); const to = boxes.get(edge.to); if (!from || !to) return;'
        'const fromLane = lanes.get(from.lane); const toLane = lanes.get(to.lane); if (!fromLane || !toLane) return;'
        'let d;'
        'if (matchMedia("(max-width: 64rem)").matches) {'
        'const rail = 4 + index * 3.2;'
        'd = `M ${from.left} ${from.cy} H ${rail} V ${to.cy} H ${to.left}`;'
        '} else if (from.lane === to.lane) {'
        'const siblings = Array.from(map.querySelectorAll(`[data-lane-id="${CSS.escape(from.lane)}"][data-node-id]`));'
        'const sourceIndex = siblings.indexOf(from.element); const targetIndex = siblings.indexOf(to.element);'
        'if (Math.abs(sourceIndex-targetIndex) === 1) {'
        'const down = targetIndex > sourceIndex; d = `M ${from.cx} ${down ? from.bottom : from.top} V ${down ? to.top : to.bottom}`;'
        '} else {'
        'const rail = fromLane.rect.left - bounds.left + 4 + (index % 3) * 3;'
        'd = `M ${from.left} ${from.cy} H ${rail} V ${to.cy} H ${to.left}`;'
        '}'
        '} else if (edge.laneDistance === 1) {'
        'const rightward = toLane.index > fromLane.index;'
        'const startX = rightward ? from.right : from.left; const endX = rightward ? to.left : to.right;'
        'const corridor = rightward ? (fromLane.rect.right + toLane.rect.left) / 2 - bounds.left : (fromLane.rect.left + toLane.rect.right) / 2 - bounds.left;'
        'd = `M ${startX} ${from.cy} H ${corridor} V ${to.cy} H ${endX}`;'
        '} else {'
        'const rail = edge.laneDistance % 2 === 0 ? 4 + (index % 4) * 3 : width - 4 - (index % 4) * 3;'
        'd = `M ${from.cx} ${from.top} V 4 H ${rail} V ${to.top} H ${to.cx}`;'
        '}'
        'const path = document.createElementNS(ns, "path"); path.setAttribute("d", d); path.setAttribute("class", "vya-edge"); path.dataset.status = edge.status; path.setAttribute("marker-end", `url(#vya-arrow-${edge.status})`);'
        'const title = document.createElementNS(ns, "title"); title.textContent = `${nodesLabel(edge.from)} → ${nodesLabel(edge.to)}: ${edge.label} (${edge.status})`; path.appendChild(title); svg.appendChild(path);'
        '});'
        '};'
        'const nodesLabel = id => root.querySelector(`[data-node-id="${CSS.escape(id)}"] .vya-node-title`)?.textContent || id;'
        'const schedule = () => requestAnimationFrame(draw);'
        'new ResizeObserver(schedule).observe(map);'
        'for (const node of map.querySelectorAll("[data-node-id]")) new ResizeObserver(schedule).observe(node);'
        'requestAnimationFrame(draw);'
        '})();</script>'
        '</section>'
    )


def _fragment_css() -> str:
    return """
#vityo-system-architecture.vya-root {
  box-sizing: border-box;
  max-width: 100%;
  min-width: 0;
  color: var(--foreground);
  font-family: inherit;
}
#vityo-system-architecture *, #vityo-system-architecture *::before,
#vityo-system-architecture *::after { box-sizing: border-box; }
#vityo-system-architecture h1, #vityo-system-architecture h2,
#vityo-system-architecture h3, #vityo-system-architecture p { margin-block: 0 0.65rem; }
#vityo-system-architecture h1, #vityo-system-architecture h2,
#vityo-system-architecture h3 { font-weight: 500; }
#vityo-system-architecture code { overflow-wrap: anywhere; }
#vityo-system-architecture .vya-header,
#vityo-system-architecture .vya-lane { min-width: 0; }
#vityo-system-architecture .vya-header { padding-block: 0.25rem 1rem; }
#vityo-system-architecture .vya-muted { color: var(--muted-foreground); }
#vityo-system-architecture .vya-legend {
  display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; list-style: none;
  margin: 0.75rem 0 0; padding: 0;
}
#vityo-system-architecture .vya-map { position: relative; min-width: 0; }
#vityo-system-architecture .vya-edges {
  position: absolute; inset: 0; z-index: 0; width: 100%; height: 100%;
  overflow: visible; pointer-events: none;
}
#vityo-system-architecture .vya-edges marker path { stroke: none; fill: color-mix(in srgb, var(--muted-foreground) 68%, var(--foreground)); }
#vityo-system-architecture .vya-edge { fill: none; stroke: color-mix(in srgb, var(--muted-foreground) 74%, var(--foreground)); stroke-width: 1.25; opacity: 0.72; }
#vityo-system-architecture .vya-edge[data-status="target"] { stroke-dasharray: 5 4; }
#vityo-system-architecture .vya-edge[data-status="gap"] { stroke-dasharray: 2 4; stroke-linecap: round; }
#vityo-system-architecture .vya-lanes {
  position: relative; z-index: 1;
  display: grid; grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 1rem; align-items: start;
}
#vityo-system-architecture .vya-lane {
  min-width: 0; border-top: 1px solid var(--border); padding-top: 0.65rem;
}
#vityo-system-architecture .vya-nodes { display: grid; gap: 0.5rem; padding-inline-start: 0.85rem; }
#vityo-system-architecture .vya-node {
  min-width: 0; padding: 0.55rem 0.65rem; overflow-wrap: anywhere;
  border: 1px solid var(--border);
  border-inline-start-width: 0.2rem;
  background: var(--card);
}
#vityo-system-architecture .vya-node[data-status="current"] { border-inline-start-color: color-mix(in srgb, var(--viz-series-1) 55%, var(--foreground)); }
#vityo-system-architecture .vya-node[data-status="target"] { border-inline-start-color: color-mix(in srgb, var(--viz-series-2) 55%, var(--foreground)); }
#vityo-system-architecture .vya-node[data-status="gap"] { border-inline-start-color: color-mix(in srgb, var(--viz-series-3) 55%, var(--foreground)); }
#vityo-system-architecture .vya-status { display: inline-flex; align-items: center; gap: 0.35rem; color: var(--foreground); font-weight: 500; white-space: nowrap; }
#vityo-system-architecture .vya-status::before { content: ""; width: 0.45rem; height: 0.45rem; border-radius: 50%; background: var(--muted-foreground); }
#vityo-system-architecture .vya-status[data-status="current"]::before { background: color-mix(in srgb, var(--viz-series-1) 55%, var(--foreground)); }
#vityo-system-architecture .vya-status[data-status="target"]::before { background: color-mix(in srgb, var(--viz-series-2) 55%, var(--foreground)); }
#vityo-system-architecture .vya-status[data-status="gap"]::before { background: color-mix(in srgb, var(--viz-series-3) 55%, var(--foreground)); }
#vityo-system-architecture .vya-node-summary { display: flex; align-items: baseline; flex-wrap: wrap; gap: 0.25rem 0.5rem; }
#vityo-system-architecture .vya-node-title { font-weight: 500; }
#vityo-system-architecture .vya-node-detail .vya-node-caption { color: var(--muted-foreground); }
#vityo-system-architecture .vya-node-detail { padding-top: 0.65rem; }
#vityo-system-architecture .vya-node-detail ul { margin-block: 0.25rem 0.75rem; padding-inline-start: 1.2rem; }
#vityo-system-architecture .vya-node-detail li { margin-block: 0.25rem; }
#vityo-system-architecture details { margin-top: 0.5rem; }
@media (max-width: 64rem) {
  #vityo-system-architecture .vya-lanes { grid-template-columns: minmax(0, 1fr); padding-inline-start: 3.5rem; }
}
"""


def render_document(model: dict[str, object], watch: bool = False) -> str:
    watcher = ""
    if watch:
        snapshot = json.dumps(model, ensure_ascii=True, separators=(",", ":")).replace("</", "<\\/")
        watcher = f"""<script>
(() => {{
  const expected = {snapshot};
  const check = async () => {{
    try {{
      const response = await fetch('/system-architecture.json', {{ cache: 'no-store' }});
      if (!response.ok) return;
      const next = await response.json();
      if (JSON.stringify(next) !== JSON.stringify(expected)) window.location.reload();
    }} catch {{}}
  }};
  window.setInterval(check, 1200);
}})();
</script>"""
    return (
        "<!doctype html>\n<html lang=\"en\"><head>\n"
        "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        f"<title>{html.escape(model['title'])}</title>\n"
        "<style>html{color-scheme:light dark;--background:Canvas;--foreground:CanvasText;--card:Canvas;"
        "--border:color-mix(in srgb,CanvasText 35%,Canvas);--muted-foreground:GrayText;"
        "--viz-series-1:LinkText;--viz-series-2:color-mix(in srgb,LinkText 70%,CanvasText 30%);"
        "--viz-series-3:Mark}body{box-sizing:border-box;margin:0;padding:1rem;"
        "color:var(--foreground);background:var(--background);font-family:system-ui,sans-serif}"
        "</style></head><body>\n"
        f"{render_fragment(model)}\n{watcher}\n</body></html>\n"
    )


def generated_outputs(root: Path, model: dict[str, object]) -> dict[Path, str]:
    markdown_path = _safe_repo_path(root, MARKDOWN_PATH.as_posix())
    if not markdown_path.is_file():
        raise ArchitectureError(f"system architecture Markdown is missing: {MARKDOWN_PATH}")
    try:
        existing_markdown = markdown_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ArchitectureError(f"cannot read system architecture Markdown: {MARKDOWN_PATH}") from error
    return {
        markdown_path: render_markdown(model, existing_markdown),
        _safe_repo_path(root, HTML_PATH.as_posix()): render_document(model),
    }


def write_outputs(root: Path, model: dict[str, object]) -> list[str]:
    root = root.resolve()
    changed: list[str] = []
    for path, content in generated_outputs(root, model).items():
        if path.is_file() and path.read_text(encoding="utf-8") == content:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        changed.append(path.relative_to(root).as_posix())
    return changed


def check_outputs(root: Path, model: dict[str, object]) -> None:
    root = root.resolve()
    for path, expected in generated_outputs(root, model).items():
        if not path.is_file():
            raise ArchitectureError(f"generated architecture output is missing: {path.relative_to(root)}")
        actual = path.read_text(encoding="utf-8")
        if actual != expected:
            raise ArchitectureError(f"generated architecture output is stale: {path.relative_to(root)}")


def _handler(root: Path, watch: bool) -> type[BaseHTTPRequestHandler]:
    last_model = load_model(root)
    generator_path = Path(__file__).resolve()
    generator_mtime_ns = generator_path.stat().st_mtime_ns
    state_lock = threading.Lock()

    class ArchitectureHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib request handler API
            nonlocal last_model
            path = urlsplit(self.path).path
            if path == "/favicon.ico":
                self._send(204, "image/x-icon", "")
                return
            if path not in {"/", "/system-architecture.html", "/system-architecture.json"}:
                self._send(404, "text/plain; charset=utf-8", "not found\n")
                return
            try:
                model = load_model(root)
                with state_lock:
                    generator_changed = generator_path.stat().st_mtime_ns != generator_mtime_ns
                    if not generator_changed and model != last_model:
                        write_outputs(root, model)
                        last_model = model
                if path != "/system-architecture.json" and generator_changed:
                    self._send(
                        503,
                        "text/plain; charset=utf-8",
                        "architecture viewer source changed; restart the viewer\n",
                    )
                    return
                if path == "/system-architecture.json":
                    body = json.dumps(model, ensure_ascii=False, indent=2) + "\n"
                    content_type = "application/json; charset=utf-8"
                else:
                    body = render_document(model, watch=watch)
                    content_type = "text/html; charset=utf-8"
                self._send(200, content_type, body)
            except ArchitectureError:
                self._send(503, "text/plain; charset=utf-8", "architecture model is invalid\n")

        def _send(self, status: int, content_type: str, body: str) -> None:
            payload = body.encode("utf-8")
            try:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(payload)
            except ConnectionError:
                pass

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    return ArchitectureHandler


def serve(root: Path, port: int, watch: bool) -> None:
    model = load_model(root)
    write_outputs(root, model)
    server = ThreadingHTTPServer(("127.0.0.1", port), _handler(root, watch))
    print(f"Architecture viewer listening at http://127.0.0.1:{server.server_port}/")
    if watch:
        print("Watch mode is enabled; model changes refresh the viewer and generated outputs.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="validate the model and regenerate outputs")
    mode.add_argument("--check", action="store_true", help="validate the model and generated-output drift")
    mode.add_argument("--fragment", action="store_true", help="write the no-fetch HTML fragment to stdout")
    mode.add_argument("--serve", action="store_true", help="serve the viewer on 127.0.0.1")
    parser.add_argument("--watch", action="store_true", help="refresh the viewer when the model changes (requires --serve)")
    parser.add_argument("--port", type=int, default=8765, help="localhost viewer port (default: 8765)")
    arguments = parser.parse_args(argv)
    if arguments.watch and not arguments.serve:
        parser.error("--watch requires --serve")
    if not 0 <= arguments.port <= 65535:
        parser.error("--port must be between 0 and 65535")

    try:
        if arguments.serve:
            serve(REPOSITORY_ROOT, arguments.port, arguments.watch)
            return 0
        model = load_model(REPOSITORY_ROOT)
        if arguments.write:
            changed = write_outputs(REPOSITORY_ROOT, model)
            print("architecture outputs updated" if changed else "architecture outputs already current")
        elif arguments.check:
            check_outputs(REPOSITORY_ROOT, model)
            print("architecture model, source boundaries, and generated outputs are current")
        else:
            sys.stdout.write(render_fragment(model))
    except ArchitectureError as error:
        print(f"architecture check failed: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"architecture command failed: {error.__class__.__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
