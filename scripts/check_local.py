"""Optional Windows syntax/config checks; NOT an Xcode compile or an iPhone test."""
from pathlib import Path
import ast
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/qa-tools"))
from tree_sitter import Language, Parser
import tree_sitter_swift
import yaml


def main():
    parser = Parser(Language(tree_sitter_swift.language()))
    failures = []
    for path in sorted((ROOT / "Sources").glob("*.swift")) + sorted((ROOT / "Tests").glob("*.swift")) + sorted((ROOT / "Watch").glob("*.swift")):
        source = path.read_bytes()
        tree = parser.parse(source)
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type == "ERROR" or node.is_missing:
                failures.append(f"{path.name}:{node.start_point.row + 1}: {node.type}: {source[node.start_byte:node.end_byte].decode()[:100]}")
            stack.extend(reversed(node.children))
    for directory in ["scripts", "Python", "tests_python"]:
        for path in (ROOT / directory).glob("*.py"):
            ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    project = yaml.safe_load((ROOT / "project.yml").read_text())
    workflow = yaml.safe_load((ROOT / ".github/workflows/ios.yml").read_text())
    assert project["targets"]["UTubeMusic"]["info"]["properties"]["UIBackgroundModes"] == ["audio"]
    job = workflow["jobs"]["build"]
    assert job["if"] == "github.event.repository.private == false"
    assert job["runs-on"] == "macos-15"
    assert "secrets" not in (ROOT / ".github/workflows/ios.yml").read_text()
    native = next(s for s in job["steps"] if s.get("name") == "Native build and queue/library tests")
    assert "set -euo pipefail" in native["run"], "A failing xcodebuild must stop IPA packaging"
    if failures:
        raise SystemExit("\n".join(failures))
    print("Swift syntax trees, Python syntax and workflow configuration: OK (not a native compilation)")


if __name__ == "__main__": main()
