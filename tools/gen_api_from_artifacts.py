#!/usr/bin/env python3
"""Render API_REFERENCE.md from the solc AST only — no forge doc, no userdoc/devdoc.

Everything comes from the compiler's AST (build it with `forge build --ast`):
  * constructors and public/external functions             -> their `documentation` node
  * public state-variable getters, ABI structs and enums    -> their `documentation` node
  * events and errors                                       -> their `documentation` node
  * `@inheritdoc X` on a member is resolved here, by reading X's member documentation directly
    (userdoc/devdoc are lossy: they drop getters' @dev entirely and mush multi-@dev together)
  * signatures and types are rebuilt from the declaration nodes
  * `type Id` (solc never records its natspec anywhere) gets a hardcoded fallback line

Internal and private implementation details are intentionally excluded. Run via `make doc`.
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
API_REFERENCE = ROOT / "API_REFERENCE.md"
BASE = 2

CORE = "LidoLend.sol/LidoLend.json"
IMORPHO = "IMorpho.sol/IMorpho.json"
ILIDOLEND = "ILidoLend.sol/ILidoLend.json"
CONTROLLER = "ILidoLendMarketController.sol/ILidoLendMarketController.json"
EVENTS = "EventsLib.sol/EventsLib.json"
ERRORS = "ErrorsLib.sol/ErrorsLib.json"

# solc does not emit natspec for `type X is Y` into any artifact, so supply Id's line by hand.
ID_FALLBACK = "A market identifier, the `keccak256` hash of a `MarketParams`."


# --------------------------------------------------------------------------- ast access

_ARTIFACTS = {}


def artifact_of(rel: str) -> dict:
    if rel in _ARTIFACTS:
        return _ARTIFACTS[rel]
    path = OUT / rel
    if not path.exists():
        sys.exit(f"missing artifact: {path}\nrun `forge build --ast` first")
    art = json.loads(path.read_text())
    if "ast" not in art:
        sys.exit(f"{rel} has no `ast` — rebuild with `forge build --ast`")
    _ARTIFACTS[rel] = art
    return art


def ast_of(rel: str) -> dict:
    return artifact_of(rel)["ast"]


def doc_text(node: dict):
    d = node.get("documentation")
    return d.get("text") if isinstance(d, dict) else d if isinstance(d, str) else None


def find(node, node_type: str, name: str):
    if isinstance(node, dict):
        if node.get("nodeType") == node_type and node.get("name") == name:
            return node
        for v in node.values():
            hit = find(v, node_type, name)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find(v, node_type, name)
            if hit is not None:
                return hit
    return None


def find_all(node, node_type: str, acc=None):
    acc = [] if acc is None else acc
    if isinstance(node, dict):
        if node.get("nodeType") == node_type:
            acc.append(node)
        for v in node.values():
            find_all(v, node_type, acc)
    elif isinstance(node, list):
        for v in node:
            find_all(v, node_type, acc)
    return acc


# --------------------------------------------------------------------------- natspec

def parse_natspec(text):
    res = {"notice": None, "dev": [], "params": {}, "returns": [], "inheritdoc": None,
           "title": None, "author": None}
    if not text:
        return res
    tokens = re.split(r"@(\w+)", text)  # [preamble, tag, body, tag, body, ...]
    it = iter(tokens[1:])
    for tag, body in zip(it, it):
        flat = " ".join(body.split())  # single-line form for key/value tags
        if tag == "notice":
            res["notice"] = body.strip("\n")  # keep raw: @dev/@notice may carry lists and breaks
        elif tag == "dev":
            res["dev"].append(body.strip("\n"))
        elif tag == "param":
            name, _, desc = flat.partition(" ")
            res["params"][name] = desc
        elif tag == "return":
            res["returns"].append(flat)
        elif tag == "inheritdoc":
            res["inheritdoc"] = flat
        elif tag in ("title", "author"):
            res[tag] = flat
    return res


def build_registry(asts):
    """(interfaceName, functionSelector) -> interface function node."""
    reg = {}
    for ast in asts:
        for c in find_all(ast, "ContractDefinition"):
            for m in c.get("nodes", []):
                selector = m.get("functionSelector")
                if m.get("nodeType") == "FunctionDefinition" and selector:
                    reg[(c["name"], selector)] = m
    return reg


def inherited_function(node, reg):
    nd = parse_natspec(doc_text(node))
    if not nd["inheritdoc"]:
        return None
    selector = node.get("functionSelector")
    base = reg.get((nd["inheritdoc"], selector))
    if base is None:
        sys.exit(
            f"unresolved @inheritdoc {nd['inheritdoc']} for {node.get('name')}"
            f" (selector {selector or 'missing'})"
        )
    return base


def resolve_doc(node, reg):
    """Parsed natspec for a member, following one level of `@inheritdoc` into the base interface."""
    nd = parse_natspec(doc_text(node))
    if nd["inheritdoc"]:
        base = inherited_function(node, reg)
        nd = parse_natspec(doc_text(base))
    return nd


# --------------------------------------------------------------------------- types

def short_type(type_name) -> str:
    s = (type_name or {}).get("typeDescriptions", {}).get("typeString", "")
    for prefix in ("struct ", "enum ", "contract ", "interface "):
        if s.startswith(prefix):
            s = s[len(prefix):]
            break
    if "." in s and "(" not in s and " " not in s:  # ILidoLendMarketController.HookEvent -> HookEvent
        s = s.rsplit(".", 1)[-1]
    return s


def normalized_internal_type(value: str) -> str:
    value = (value or "").strip()
    for prefix in ("struct ", "enum ", "contract ", "interface "):
        if value.startswith(prefix):
            return value[len(prefix):]
    return value


def render_param(v: dict) -> str:
    parts = [short_type(v.get("typeName"))]
    if v.get("storageLocation") in ("memory", "calldata", "storage"):
        parts.append(v["storageLocation"])
    if v.get("name"):
        parts.append(v["name"])
    return " ".join(parts)


def modifier_invocation(modifier: dict) -> str:
    name = modifier.get("modifierName", {}).get("name", "")
    arguments = modifier.get("arguments")
    if arguments is None:
        return name
    if not arguments:
        return f"{name}()"
    return f"{name}(...)"


def function_signature(fn: dict) -> str:
    params = [render_param(p) for p in fn["parameters"]["parameters"]]
    if fn.get("kind") == "constructor":
        head, tail = "constructor", ""
    else:
        head = f"function {fn.get('name', '')}"
        tail = ""
        if fn.get("visibility"):
            tail += f" {fn['visibility']}"
        for modifier in fn.get("modifiers", []):
            tail += f" {modifier_invocation(modifier)}"
        if fn.get("stateMutability") in ("view", "pure", "payable"):
            tail += f" {fn['stateMutability']}"
        if fn.get("virtual"):
            tail += " virtual"
        rets = fn["returnParameters"]["parameters"]
        if rets:
            tail += " returns (" + ", ".join(render_param(r) for r in rets) + ")"
    oneline = f"{head}({', '.join(params)}){tail};"
    if len(oneline) <= 80 or not params:  # wrap long signatures one parameter per line
        return oneline
    body = ",\n".join(f"    {p}" for p in params)
    return f"{head}(\n{body}\n){tail};"


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def type_slug(type_name: dict) -> str:
    value = short_type(type_name).replace("[]", "-array")
    return slug(value)


def readable_function_anchor(contract_name: str, fn: dict) -> str:
    name = "constructor" if fn.get("kind") == "constructor" else fn.get("name", "")
    parts = [slug(contract_name), "function", slug(name)]
    parts.extend(type_slug(p.get("typeName")) for p in fn.get("parameters", {}).get("parameters", []))
    return "-".join(part for part in parts if part)


def selector_anchor(contract_name: str, kind: str, name: str, selector: str) -> str:
    parts = [slug(contract_name), kind, slug(name)]
    if selector:
        parts.append(selector.lower())
    return "-".join(parts)


def anchors(*values: str) -> list:
    unique = list(dict.fromkeys(value for value in values if value))
    return [f'<a id="{value}"></a>' for value in unique] + [""]


# --------------------------------------------------------------------------- markdown

def md_table(header, rows) -> list:
    out = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    return out + ["| " + " | ".join(r) + " |" for r in rows]


def normalize(text: str) -> str:
    return re.sub(r"([.!?])([A-Z`])", r"\1 \2", text)  # space out abutting sentences if any


def render_block(text: str) -> list:
    """Format one natspec tag body as markdown: join soft-wrapped lines, keep `-` bullet lists,
    keep blank-line paragraph breaks."""
    items = []  # ('p' | 'li' | 'break', text)
    for ln in text.split("\n"):
        ln = ln.strip()
        if not ln:
            items.append(("break", ""))
        elif ln.startswith("- "):
            items.append(("li", ln[2:].strip()))
        elif items and items[-1][0] in ("p", "li"):  # continuation of a wrapped line
            items[-1] = (items[-1][0], (items[-1][1] + " " + ln).strip())
        else:
            items.append(("p", ln))
    out, prev = [], None
    for kind, txt in items:
        if kind == "break":
            prev = None
            continue
        txt = normalize(txt)
        if kind == "p" and re.match(r"(?i)warning\b\s*:?", txt):  # render a `Warning:` para as a GitHub alert
            body = re.sub(r"(?i)^warning\b\s*:?\s*", "", txt)
            if out and out[-1] != "":
                out.append("")
            out += ["> [!WARNING]", f"> {body}", ""]
            prev = None
            continue
        if out and (kind == "p" or prev == "p"):  # blank line before a paragraph or a list after one
            out.append("")
        out.append(f"- {txt}" if kind == "li" else txt)
        prev = kind
    return out


def paras(*texts) -> list:
    out = []
    for t in texts:
        if t:
            out += render_block(t) + [""]
    return out


def render_callable(fn, nd, level, name, anchor_values) -> list:
    out = anchors(*anchor_values) + [f"{'#' * level} `{name}`", ""]
    out += ["```solidity", function_signature(fn), "```", ""]  # signature, then its parameter tables

    prows = [(f"`{p['name']}`", f"`{short_type(p['typeName'])}`", nd["params"].get(p["name"], ""))
             for p in fn["parameters"]["parameters"] if p.get("name")]
    if any(r[2].strip() for r in prows):
        out += ["**Parameters**", ""] + md_table(("Name", "Type", "Description"), prows) + [""]

    ret_descs = {}
    for entry in nd["returns"]:
        head, _, rest = entry.partition(" ")
        ret_descs[head] = rest
    rrows = []
    for i, r in enumerate(fn["returnParameters"]["parameters"]):
        if r.get("name"):
            name_cell = f"`{r['name']}`"
            desc = ret_descs.get(r["name"], "")
        else:  # unnamed return — match forge doc's `<none>`, keep the raw @return text as the description
            name_cell = "`<none>`"
            desc = nd["returns"][i] if i < len(nd["returns"]) else ""
        rrows.append((name_cell, f"`{short_type(r['typeName'])}`", desc))
    if any(r[2].strip() for r in rrows):
        out += ["**Returns**", ""] + md_table(("Name", "Type", "Description"), rrows) + [""]

    out += paras(nd["notice"], *nd["dev"])  # description and notes after the interface
    return out


def render_function(fn, reg, level, contract_name, include_short_anchor, include_readable_anchor) -> list:
    name = "constructor" if fn.get("kind") == "constructor" else fn.get("name", "")
    selector = fn.get("functionSelector", "")
    stable_anchor = selector_anchor(contract_name, "function", name, selector)
    readable_anchor = readable_function_anchor(contract_name, fn) if include_readable_anchor else ""
    short_anchor = f"{slug(contract_name)}-{slug(name)}" if include_short_anchor else ""
    return render_callable(
        fn,
        resolve_doc(fn, reg),
        level,
        name,
        (stable_anchor, readable_anchor, short_anchor),
    )


def render_getter(variable, reg, level, contract_name) -> list:
    getter = inherited_function(variable, reg)
    if getter is None:
        sys.exit(f"public getter {variable['name']} has no interface declaration")
    selector = variable.get("functionSelector", "")
    prefix = slug(contract_name)
    return render_callable(
        getter,
        resolve_doc(variable, reg),
        level,
        variable["name"],
        (
            selector_anchor(contract_name, "getter", variable["name"], selector),
            f"{prefix}-getter-{slug(variable['name'])}",
            f"{prefix}-{slug(variable['name'])}",
        ),
    )


def render_struct(node, level, contract_name) -> list:
    nd = parse_natspec(doc_text(node))
    prefix = slug(contract_name)
    out = anchors(f"{prefix}-struct-{slug(node['name'])}", f"{prefix}-{slug(node['name'])}")
    out += [f"{'#' * level} `{node['name']}`", ""]
    body = [f"    {short_type(m['typeName'])} {m['name']};" for m in node["members"]]
    out += ["```solidity", f"struct {node['name']} {{", *body, "}", "```", ""]
    out += paras(nd["notice"], *nd["dev"])
    rows = [(f"`{m['name']}`", f"`{short_type(m['typeName'])}`", nd["params"].get(m["name"], ""))
            for m in node["members"]]
    # Skip the table when no field has a description: the solidity block above already lists
    # names and types, so an undocumented struct gains nothing from repeating them.
    if any(r[2] for r in rows):
        out += ["**Fields**", ""] + md_table(("Name", "Type", "Description"), rows) + [""]
    return out


def render_enum(node, level, contract_name) -> list:
    nd = parse_natspec(doc_text(node))
    prefix = slug(contract_name)
    out = anchors(f"{prefix}-enum-{slug(node['name'])}", f"{prefix}-{slug(node['name'])}")
    out += [f"{'#' * level} `{node['name']}`", ""]
    body = ",\n".join(f"    {m['name']}" for m in node["members"])
    out += ["```solidity", f"enum {node['name']} {{", body, "}", "```", ""]
    out += paras(nd["notice"], *nd["dev"])
    return out


def validate_callable_surface(rel: str, node: dict) -> None:
    expected = artifact_of(rel).get("methodIdentifiers", {})
    expected_by_selector = {}
    for signature, selector in expected.items():
        if selector in expected_by_selector:
            sys.exit(
                f"selector collision in {rel}: {signature} and "
                f"{expected_by_selector[selector]} both use {selector}"
            )
        expected_by_selector[selector] = signature

    actual_by_selector = {}
    for member in node["nodes"]:
        is_callable = (
            member.get("nodeType") == "FunctionDefinition"
            and member.get("kind") != "constructor"
            and member.get("visibility") in ("public", "external")
        )
        is_getter = (
            member.get("nodeType") == "VariableDeclaration"
            and member.get("stateVariable")
            and member.get("visibility") == "public"
        )
        if not (is_callable or is_getter):
            continue

        selector = member.get("functionSelector")
        label = member.get("name") or member.get("kind", "callable")
        if not selector:
            sys.exit(f"missing selector for {node['name']}.{label}")
        if selector in actual_by_selector:
            sys.exit(
                f"duplicate selector {selector} in rendered {node['name']} surface: "
                f"{actual_by_selector[selector]} and {label}"
            )
        actual_by_selector[selector] = label

    missing = sorted(set(expected_by_selector) - set(actual_by_selector))
    unexpected = sorted(set(actual_by_selector) - set(expected_by_selector))
    if missing or unexpected:
        details = []
        if missing:
            details.append(
                "missing from AST selection: "
                + ", ".join(f"{expected_by_selector[s]} ({s})" for s in missing)
            )
        if unexpected:
            details.append(
                "missing from ABI method identifiers: "
                + ", ".join(f"{actual_by_selector[s]} ({s})" for s in unexpected)
            )
        sys.exit(f"incomplete callable API for {node['name']}: " + "; ".join(details))


def render_contract(rel, name, reg, level, include_declared_types=False) -> list:
    node = find(ast_of(rel), "ContractDefinition", name)
    validate_callable_surface(rel, node)
    nd = parse_natspec(doc_text(node))  # contract-level natspec has no @inheritdoc
    out = anchors(slug(name)) + [f"{'#' * level} `{name}`", ""]
    out += paras(nd["notice"], *nd["dev"])

    members = node["nodes"]
    statevars = [n for n in members if n.get("nodeType") == "VariableDeclaration"
                 and n.get("stateVariable") and n.get("visibility") == "public"]
    funcs = [n for n in members if n.get("nodeType") == "FunctionDefinition"
             and (n.get("kind") == "constructor" or n.get("visibility") in ("public", "external"))]
    enums = [n for n in members if n.get("nodeType") == "EnumDefinition"] if include_declared_types else []
    structs = [n for n in members if n.get("nodeType") == "StructDefinition"] if include_declared_types else []

    if funcs:
        funcs = sorted(funcs, key=lambda f: 0 if f.get("kind") == "constructor" else 1)
        out += anchors(f"{slug(name)}-functions")
        out += [f"{'#' * (level + 1)} Functions", ""]
        readable_counts = Counter(readable_function_anchor(name, fn) for fn in funcs)
        for fn in funcs:
            fn_name = "constructor" if fn.get("kind") == "constructor" else fn.get("name", "")
            unique_name = sum(
                1 for candidate in funcs
                if ("constructor" if candidate.get("kind") == "constructor" else candidate.get("name", "")) == fn_name
            ) == 1
            unique_readable = readable_counts[readable_function_anchor(name, fn)] == 1
            out += render_function(fn, reg, level + 2, name, unique_name, unique_readable)

    if enums:
        out += anchors(f"{slug(name)}-enums")
        out += [f"{'#' * (level + 1)} Enums", ""]
        for e in enums:
            out += render_enum(e, level + 2, name)

    if structs:
        out += anchors(f"{slug(name)}-structs")
        out += [f"{'#' * (level + 1)} Structs", ""]
        for s in structs:
            out += render_struct(s, level + 2, name)

    if statevars:
        out += anchors(f"{slug(name)}-getters")
        out += [f"{'#' * (level + 1)} Public getters", ""]
        for v in statevars:
            out += render_getter(v, reg, level + 2, name)
    return out


def readable_event_anchor(contract_name: str, node: dict) -> str:
    parts = [slug(contract_name), "event", slug(node["name"])]
    parts.extend(type_slug(p.get("typeName")) for p in node["parameters"]["parameters"])
    return "-".join(part for part in parts if part)


def event_ast_key(node: dict) -> tuple:
    parameters = node["parameters"]["parameters"]
    return (
        node["name"],
        tuple(
            normalized_internal_type(p["typeName"]["typeDescriptions"]["typeString"])
            for p in parameters
        ),
        tuple(bool(p.get("indexed")) for p in parameters),
        bool(node.get("anonymous")),
    )


def event_abi_key(node: dict) -> tuple:
    return (
        node["name"],
        tuple(normalized_internal_type(p.get("internalType") or p["type"]) for p in node["inputs"]),
        tuple(bool(p.get("indexed")) for p in node["inputs"]),
        bool(node.get("anonymous")),
    )


def validate_event_surface(events: list) -> None:
    abi_events = [item for item in artifact_of(CORE).get("abi", []) if item.get("type") == "event"]
    ast_keys = Counter(event_ast_key(event) for event in events)
    abi_keys = Counter(event_abi_key(event) for event in abi_events)
    if ast_keys != abi_keys:
        missing = list((abi_keys - ast_keys).elements())
        unexpected = list((ast_keys - abi_keys).elements())
        details = []
        if missing:
            details.append("missing from EventsLib AST: " + ", ".join(map(str, missing)))
        if unexpected:
            details.append("missing from core ABI: " + ", ".join(map(str, unexpected)))
        sys.exit("incomplete event API: " + "; ".join(details))


def render_event(node, level, contract_name, include_short_anchor, include_readable_anchor) -> list:
    nd = parse_natspec(doc_text(node))
    params = []
    for p in node["parameters"]["parameters"]:
        parts = [short_type(p["typeName"])]
        if p.get("indexed"):
            parts.append("indexed")
        if p.get("name"):
            parts.append(p["name"])
        params.append(" ".join(parts))
    sig = f"event {node['name']}({', '.join(params)});"
    if len(sig) > 80 and params:
        sig = f"event {node['name']}(\n" + ",\n".join(f"    {p}" for p in params) + "\n);"
    prefix = slug(contract_name)
    stable_anchor = selector_anchor(contract_name, "event", node["name"], node.get("eventSelector", ""))
    readable_anchor = readable_event_anchor(contract_name, node) if include_readable_anchor else ""
    short_anchor = f"{prefix}-{slug(node['name'])}" if include_short_anchor else ""
    out = anchors(stable_anchor, readable_anchor, short_anchor)
    out += [f"{'#' * level} `{node['name']}`", "", "```solidity", sig, "```", ""]
    out += paras(nd["notice"], *nd["dev"])
    rows = [(f"`{p['name']}`", f"`{short_type(p['typeName'])}`", nd["params"].get(p["name"], ""))
            for p in node["parameters"]["parameters"] if p.get("name")]
    if any(r[2] for r in rows):
        out += ["**Parameters**", ""] + md_table(("Name", "Type", "Description"), rows) + [""]
    return out


def render_events(level) -> list:
    lib = find(ast_of(EVENTS), "ContractDefinition", "EventsLib")
    out = anchors("eventslib-events") + [f"{'#' * level} Events (`EventsLib`)", ""]
    events = [n for n in lib["nodes"] if n.get("nodeType") == "EventDefinition"]
    validate_event_surface(events)
    readable_counts = Counter(readable_event_anchor("EventsLib", event) for event in events)
    for ev in events:
        unique_name = sum(1 for candidate in events if candidate.get("name") == ev.get("name")) == 1
        unique_readable = readable_counts[readable_event_anchor("EventsLib", ev)] == 1
        out += render_event(ev, level + 1, "EventsLib", unique_name, unique_readable)
    return out


def render_errors(level) -> list:
    """One table: revert strings are flat constants, a subsection each would be noise."""
    lib = find(ast_of(ERRORS), "ContractDefinition", "ErrorsLib")
    out = anchors("errorslib-errors") + [f"{'#' * level} Errors (`ErrorsLib`)", ""]
    rows = []
    for v in lib["nodes"]:
        value = v.get("value") or {}
        if (
            v.get("nodeType") != "VariableDeclaration"
            or not v.get("constant")
            or short_type(v.get("typeName")) != "string"
            or value.get("nodeType") != "Literal"
            or value.get("kind") != "string"
        ):
            continue
        vd = parse_natspec(doc_text(v))
        notice = " ".join((vd["notice"] or "").split())
        anchor = f'<a id="errorslib-{slug(v["name"])}"></a>'
        rows.append((f'{anchor}`{v["name"]}`', f'`"{value["value"]}"`', notice))
    out += md_table(("Constant", "Revert string", "Meaning"), rows) + [""]
    return out


def validate_error_surface() -> None:
    custom_errors = [item for item in artifact_of(CORE).get("abi", []) if item.get("type") == "error"]
    if custom_errors:
        names = ", ".join(sorted(error["name"] for error in custom_errors))
        sys.exit(f"custom ABI errors are not rendered: {names}")


# --------------------------------------------------------------------------- assembly

def build_section() -> str:
    reg = build_registry([ast_of(IMORPHO), ast_of(ILIDOLEND), ast_of(CONTROLLER)])
    validate_error_surface()

    md = anchors("api-types") + [f"{'#' * BASE} Types", ""]
    id_node = find(ast_of(IMORPHO), "UserDefinedValueTypeDefinition", "Id")
    md += anchors("imorpho-type-id", "imorpho-id")
    md += [f"{'#' * (BASE + 1)} `Id`", "",
           "```solidity", f"type Id is {id_node['underlyingType']['typeDescriptions']['typeString']};", "```", "",
           ID_FALLBACK, ""]
    for struct in ("MarketParams", "Position", "Market", "Authorization", "Signature"):
        md += render_struct(find(ast_of(IMORPHO), "StructDefinition", struct), BASE + 1, "IMorpho")

    md += render_contract(CORE, "LidoLend", reg, BASE)
    md += render_contract(CONTROLLER, "ILidoLendMarketController", reg, BASE, include_declared_types=True)
    md += render_events(BASE)
    md += render_errors(BASE)

    return re.sub(r"\n{3,}", "\n\n", "\n".join(md)).strip()


def build_document() -> str:
    md = [
        "# LidoLend API Reference",
        "",
        "<!-- Generated by tools/gen_api_from_artifacts.py. Do not edit by hand; run `make doc`. -->",
        "",
        "This reference is generated from the Solidity AST. It includes constructors, public and external functions, public getters, ABI-relevant structs and enums, events, and errors.",
        "",
        "## Contents",
        "",
        "- [Types](#api-types)",
        "- [`LidoLend`](#lidolend)",
        "- [`ILidoLendMarketController`](#ilidolendmarketcontroller)",
        "- [Events](#eventslib-events)",
        "- [Errors](#errorslib-errors)",
        "",
        build_section(),
    ]
    document = re.sub(r"\n{3,}", "\n\n", "\n".join(md)).strip() + "\n"
    generated_anchors = re.findall(r'<a id="([^"]+)"></a>', document)
    duplicates = sorted({anchor for anchor in generated_anchors if generated_anchors.count(anchor) > 1})
    if duplicates:
        sys.exit("duplicate generated anchors: " + ", ".join(duplicates))
    return document


def main() -> int:
    new = build_document()
    current = API_REFERENCE.read_text() if API_REFERENCE.exists() else ""
    if new == current:
        print("API_REFERENCE.md already up to date")
        return 0
    API_REFERENCE.write_text(new)
    print(f"updated API_REFERENCE.md ({len(new.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
