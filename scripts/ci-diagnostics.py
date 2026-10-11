"""Emit fixed categories and repository-owned test/API identifiers, never log excerpts."""
import ast
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text(errors='replace')
labels = []
categories = {
    'Universal slice collision': 'have the same architectures',
    'Code signing file attributes': 'resource fork, Finder information',
    'Code signing format failure': 'bundle format unrecognized',
    'Code signing executable validation': 'main executable failed strict validation',
    'Missing build path': 'No such file or directory',
    'Build file permission failure': 'Permission denied',
    'Header unavailable': 'file not found',
    'Undeclared API': 'undeclared function',
    'Link failure': 'Undefined symbols',
    'Swift name resolution': 'cannot find',
    'Swift type mismatch': 'cannot convert',
    'Unsupported API member': 'has no member',
    'Concurrency isolation': 'actor-isolated',
    'Engine fixture assertion failure': 'AssertionError',
    'Python fixture exception': 'Traceback',
    'Ambiguous Swift expression': 'ambiguous',
    'Optional value mismatch': 'optional',
    'Invalid argument': 'argument',
    'Invalid override': 'override',
    'Invalid pattern match': 'cannot match',
    'Linker invocation failure': 'linker command failed',
    'Swift test assertion failure': 'XCTAssert',
    'Swift access control': 'inaccessible',
    'Missing protocol conformance': 'does not conform',
}
for label, pattern in categories.items():
    if pattern in text: labels.append(label)
# These literal API identifiers are public source identifiers, not extracted log text.
for name in ['archive_read_support_format_rar5', 'archive_entry_is_encrypted',
             'archive_entry_pathname_utf8', 'archive.h', 'NSStackView', 'NSAffineTransform',
             'UnicodeScalar', 'NSSearchFieldDelegate', 'NSToolbarItemValidation']:
    if name in text: labels.append('Referenced API: ' + name)
# Only names declared in our committed tests can appear in annotations.
for test_file in ['tests/test_engine.py', 'tests/test_creation.py', 'tests/test_sevenzip.py', 'tests/test_integrity.py', 'tests/test_zip_addition.py']:
    for node in ast.walk(ast.parse(Path(test_file).read_text())):
        if isinstance(node, ast.FunctionDef) and node.name.startswith('test_'):
            if re.search(r'(?:FAIL|ERROR): ' + re.escape(node.name) + r'\b', text):
                labels.append('Failing test: ' + node.name)
# Referenced identifiers must occur in repository source; never emit diagnostic text.
source_identifiers = set()
for source in Path('Sources').rglob('*.swift'):
    source_identifiers.update(re.findall(r'\b[A-Za-z_][A-Za-z_0-9]*\b', source.read_text()))
for line in text.splitlines():
    if 'error:' not in line: continue
    for identifier in re.findall(r"'([A-Za-z_][A-Za-z_0-9]*)'", line):
        if identifier in source_identifiers:
            labels.append('Referenced source identifier: ' + identifier)
for source in Path('Tests').rglob('*.swift'):
    for test in re.findall(r'func (test[A-Za-z_0-9]+)', source.read_text()):
        if re.search(re.escape(test) + r'.*(?:failed|error)', text):
            labels.append('Failing Swift test: ' + test)
labels = list(dict.fromkeys(labels))
if not labels: labels.append('Command failed; detailed diagnostics require authenticated Actions log access.')
for label in labels:
    print('::error title=Arkiv sanitized diagnostic::' + label)
