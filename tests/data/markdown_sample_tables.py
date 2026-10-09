#!/usr/bin/env python3
"""Generates tests/data/markdown_sample_tables.md, the markdown preview's table-heavy test input.

    python3 tests/data/markdown_sample_tables.py > tests/data/markdown_sample_tables.md

Seeded, so the output is the same every run. The words are noise; the shape is what the tests in
tests/integration.zig need:

- One very large table (~48KB) whose cells wrap over many lines, plus three smaller ones. A table
  whose cells wrap is what a deferred height has to get right before its rows are laid out, and
  what row culling inside a table has to keep stable while the reader scrolls through it.
- Blocks whose source repeats (rules, a stock paragraph), so source hashes are not unique and
  anchoring has to pick the nearest copy, not the first.
- One paragraph several thousand characters long, for bench-markdown's "prose" sample.

Everything after the tables is appended after them on purpose. The tests scroll in fixed steps, so
a block inserted above a table moves which frames see it, and on the parent of the change that
introduced this file such a shift was enough to hide the bug "block heights do not depend on where
the reader is" exists to catch. Check that test still fails without its fix before reshaping this.
"""

import random
import sys

random.seed(20261009)
words = (
    "table row cell column header width wrap line block layout height scroll reader position "
    "document preview measure settle frame paint glyph text span word paragraph section heading "
    "list item value field entry record sample data plugin surface region pane window view "
    "editor fizzy dvui render cache budget stable reflow sash drag offset viewport culling"
).split()


def sentence(n):
    return " ".join(random.choice(words) for _ in range(n)).capitalize() + "."


def para(k):
    return " ".join(sentence(random.randint(8, 16)) for _ in range(k))


def table(cols, rows, sentences_per_cell):
    t = ["| " + " | ".join(f"Column {c + 1}" for c in range(cols)) + " |", "|" + "---|" * cols]
    for r in range(rows):
        cells = [f"`row-{r + 1}`"] + [
            " ".join(sentence(random.randint(6, 12)) for _ in range(sentences_per_cell))
            for _ in range(cols - 1)
        ]
        t.append("| " + " | ".join(cells) + " |")
    return t


# The same source, more than once: every copy hashes alike.
stock = "This paragraph and the rule below it repeat, word for word, after every section."

out = [
    "# Markdown sample: tables",
    "",
    "A synthetic, table-heavy document for the markdown preview's layout tests: one very large table",
    "whose rows wrap over many lines, a few smaller ones, and prose between them. Its words mean",
    "nothing; its shape is what the tests need (row culling inside a table, block skipping around it).",
    "",
]
sec = 1
for cols, rows, per_cell in ((3, 29, 14), (3, 17, 2), (3, 6, 1), (3, 16, 3)):
    for _ in range(3):
        out += [f"## Section {sec}", "", para(5), ""]
        sec += 1
    out += table(cols, rows, per_cell) + [""]
for _ in range(4):
    out += [f"## Section {sec}", "", para(6), "", "- " + sentence(10), "- " + sentence(12), ""]
    out += [stock, "", "---", ""]
    sec += 1
out += [f"## Section {sec}", "", para(60), ""]
sys.stdout.write("\n".join(out))
