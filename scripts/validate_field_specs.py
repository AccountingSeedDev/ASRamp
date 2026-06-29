#!/usr/bin/env python3
"""Validate that generated Salesforce field metadata matches JIRA field specs.

Reads ISSUE_DESCRIPTION from the environment, parses field specifications
(Name/Type/Required/Length), and validates them against the generated
field-meta.xml files under force-app/main/default/objects/.

Exit codes:
  0  — No field specs found (non-field ticket) or all specs match
  1  — Mismatch detected between JIRA spec and generated metadata

Required env vars:
  ISSUE_KEY         — JIRA issue key (for error messages)
  ISSUE_DESCRIPTION — Full JIRA description text (set by fetch_jira_details.py)
"""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _normalize_expected_type(type_raw: str) -> str:
    """Normalize JIRA type description to Salesforce metadata type."""
    t = type_raw.strip().lower()
    if "lookup" in t:
        return "Lookup"
    if "master" in t and "detail" in t:
        return "MasterDetail"
    if "date/time" in t or "datetime" in t:
        return "DateTime"
    if "long text" in t:
        return "LongTextArea"
    if "text area" in t:
        return "TextArea"
    return type_raw.strip()


def _infer_api_from_label(label: str) -> str:
    """Convert a field label to its likely API name."""
    return re.sub(r"[^A-Za-z0-9]+", "_", label).strip("_") + "__c"


def _parse_xml(path: Path):
    """Parse an XML file and return (root, namespace_dict, text_getter)."""
    root = ET.parse(path).getroot()
    ns_uri = root.tag.split("}")[0].strip("{") if "}" in root.tag else ""
    ns = {"m": ns_uri} if ns_uri else {}

    def get_text(xpath):
        n = root.find(xpath, ns) if ns else root.find(xpath.replace("m:", ""))
        return (n.text or "").strip() if n is not None and n.text else ""

    return root, ns, get_text


def main():
    issue = os.environ.get("ISSUE_KEY", "UNKNOWN")
    desc = os.environ.get("ISSUE_DESCRIPTION", "") or ""

    if not desc:
        print("No ISSUE_DESCRIPTION set; skipping field validation.")
        sys.exit(0)

    # Extract object label (best-effort)
    obj_label = None
    m = re.search(r'name of the object is\s*[""\u201c]([^""\u201d]+)[""\u201d]', desc, flags=re.IGNORECASE)
    if m:
        obj_label = m.group(1).strip()

    # Extract field specs from description lines like:
    # Name: Financial Report Settings; Type: Lookup (Financial_Report_Settings__c); Required: true
    field_specs = []
    for line in desc.splitlines():
        stripped = line.strip().lstrip("\u2022*-").strip()
        if "Name:" not in stripped or "Type:" not in stripped or "Required:" not in stripped:
            continue
        m = re.search(
            r'Name:\s*([^;:]+?)\s*(?:;|:)\s*Type:\s*([^;]+?)\s*(?:;\s*Length:\s*(\d+)\s*)?(?:;|,)\s*Required:\s*(true|false)\b',
            stripped, flags=re.IGNORECASE
        )
        if not m:
            continue
        label = m.group(1).strip()
        type_raw = m.group(2).strip()
        length = m.group(3)
        required = m.group(4).lower() == "true"

        lookup_target = None
        m2 = re.search(r'lookup\s*\(\s*([A-Za-z0-9_]+__c)\s*\)', type_raw, flags=re.IGNORECASE)
        if m2:
            lookup_target = m2.group(1).strip()

        field_specs.append({
            "label": label,
            "type_raw": type_raw,
            "lookup_target": lookup_target,
            "length": int(length) if length else None,
            "required": required
        })

    if not field_specs:
        print("No parsable field specs found in ISSUE_DESCRIPTION; skipping strict field validation.")
        sys.exit(0)

    # Build field index from generated metadata
    objects_root = Path("force-app/main/default/objects")
    if not objects_root.exists():
        print(f"ERROR [{issue}]: force-app/main/default/objects/ not found.")
        sys.exit(1)

    # Load claude_files.json if present to narrow search
    changed_paths = []
    if Path("claude_files.json").exists():
        try:
            spec = json.loads(Path("claude_files.json").read_text())
            changed_paths = [f.get("path") for f in spec.get("files", []) if isinstance(f.get("path"), str)]
        except Exception as e:
            print(f"WARNING: Could not read claude_files.json: {e}")

    # Determine object API name and directory
    obj_api = _infer_api_from_label(obj_label) if obj_label else None

    obj_dirs = set()
    for p in changed_paths:
        if not p:
            continue
        m = re.search(r"force-app/main/default/objects/([^/]+)/", p)
        if m:
            obj_dirs.add(m.group(1))

    chosen_obj_dir = None
    if obj_api and (objects_root / obj_api).exists():
        chosen_obj_dir = objects_root / obj_api
    elif len(obj_dirs) == 1:
        chosen_obj_dir = objects_root / next(iter(obj_dirs))
    else:
        # fallback: try label match by scanning object-meta labels
        for obj_path in sorted(objects_root.glob("*/**/*.object-meta.xml")):
            try:
                root = ET.parse(obj_path).getroot()
            except Exception:
                continue
            ns_uri = root.tag.split("}")[0].strip("{") if "}" in root.tag else ""
            ns = {"m": ns_uri} if ns_uri else {}
            n = root.find("m:label", ns) if ns else root.find("label")
            lbl = (n.text or "").strip() if n is not None and n.text else ""
            if obj_label and lbl.lower() == obj_label.lower():
                chosen_obj_dir = obj_path.parent
                break

    if chosen_obj_dir is None:
        print(f"ERROR [{issue}]: Could not locate object folder for label {obj_label!r} / api {obj_api!r}.")
        sys.exit(1)

    # Parse fields from metadata
    fields_dir = chosen_obj_dir / "fields"
    object_meta = chosen_obj_dir / (chosen_obj_dir.name + ".object-meta.xml")

    field_index = {}  # label_lower -> dict
    api_index = {}    # api_lower -> dict

    def add_field_entry(api_name, label, ftype, required_txt, ref_to, length_txt):
        entry = {
            "api": api_name,
            "label": label,
            "type": ftype,
            "required": (required_txt or "").strip().lower() == "true",
            "required_raw": (required_txt or "").strip(),
            "referenceTo": (ref_to or "").strip(),
            "length": (length_txt or "").strip()
        }
        if label:
            field_index[label.lower()] = entry
        if api_name:
            api_index[api_name.lower()] = entry

    if fields_dir.exists():
        for fp in sorted(fields_dir.glob("*.field-meta.xml")):
            try:
                root, ns, get_text = _parse_xml(fp)
            except Exception:
                continue
            api_name = fp.name.replace(".field-meta.xml", "")
            add_field_entry(
                api_name,
                get_text("m:label"),
                get_text("m:type"),
                get_text("m:required"),
                get_text("m:referenceTo"),
                get_text("m:length"),
            )
    elif object_meta.exists():
        try:
            root, ns, _ = _parse_xml(object_meta)
        except Exception as e:
            print(f"ERROR [{issue}]: Failed to parse {object_meta}: {e}")
            sys.exit(1)

        fields_nodes = root.findall("m:fields", ns) if ns else root.findall("fields")
        for f in fields_nodes:
            def ft(xpath):
                n = f.find(xpath, ns) if ns else f.find(xpath.replace("m:", ""))
                return (n.text or "").strip() if n is not None and n.text else ""
            add_field_entry(ft("m:fullName"), ft("m:label"), ft("m:type"),
                            ft("m:required"), ft("m:referenceTo"), ft("m:length"))
    else:
        print(f"ERROR [{issue}]: Neither fields/ directory nor object-meta.xml found in {chosen_obj_dir}.")
        sys.exit(1)

    if not field_index and not api_index:
        print(f"ERROR [{issue}]: No fields could be parsed for validation (empty index) in {chosen_obj_dir}.")
        sys.exit(1)

    # Validate each spec
    errors = []
    for spec in field_specs:
        label = spec["label"]
        expected_type = _normalize_expected_type(spec["type_raw"])
        expected_required = spec["required"]
        expected_len = spec["length"]
        expected_ref = spec["lookup_target"]

        entry = field_index.get(label.lower())
        if entry is None:
            inferred = _infer_api_from_label(label)
            entry = api_index.get(inferred.lower())

        if entry is None:
            known = sorted(list(field_index.keys()))[:40]
            errors.append(f"Missing field for JIRA spec label '{label}'. Known labels (first 40): {known}")
            continue

        actual_type = entry["type"]
        if expected_type == "Lookup" and actual_type != "Lookup":
            errors.append(f"Field '{label}' expected type Lookup but got '{actual_type}'")
        if expected_type == "MasterDetail" and actual_type != "MasterDetail":
            errors.append(f"Field '{label}' expected type MasterDetail but got '{actual_type}'")
        if expected_type in ("DateTime", "LongTextArea", "TextArea") and actual_type != expected_type:
            errors.append(f"Field '{label}' expected type {expected_type} but got '{actual_type}'")

        if expected_type == "Lookup" and expected_ref:
            if entry["referenceTo"] != expected_ref:
                errors.append(f"Field '{label}' expected referenceTo '{expected_ref}' but got '{entry['referenceTo']}'")

        if expected_required and not entry["required"]:
            raw = entry["required_raw"] or "missing"
            errors.append(f"Field '{label}' expected required=true but required is not true (found '{raw}')")
        if (not expected_required) and entry["required"]:
            errors.append(f"Field '{label}' expected required=false but required=true")

        if expected_len is not None:
            if not entry["length"].isdigit() or int(entry["length"]) != expected_len:
                errors.append(f"Field '{label}' expected length {expected_len} but got '{entry['length'] or 'missing'}'")

    if errors:
        print(f"ERROR [{issue}]: Field validation failed with {len(errors)} error(s):")
        for err in errors:
            print(f"  - {err}")
        print(f"  Object context: {chosen_obj_dir}")
        sys.exit(1)

    print(f"OK: Validated {len(field_specs)} field specs in {chosen_obj_dir.name} successfully.")


if __name__ == "__main__":
    main()
