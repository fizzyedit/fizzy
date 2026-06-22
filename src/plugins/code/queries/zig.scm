; Feppz! / vscode-zig aligned captures for tree-sitter highlighting.
; Capture names mirror TextMate scopes from ziglang.vscode-zig where possible.

; --- Functions & calls (before generic identifiers) ---
(function_declaration
  name: (identifier) @feppz.entity.name.function)

(call_expression
  function: (identifier) @feppz.entity.name.function)

(call_expression
  function: (field_expression
    member: (identifier) @feppz.entity.name.function))

; const/var name — the identifier immediately after the keyword.
(variable_declaration
  [
    "const"
    "var"
  ]
  (identifier) @feppz.variable.definition)

; PascalCase types only when not a dotted path segment (see field_expression below).
((identifier) @feppz.entity.name.type
  (#match? @feppz.entity.name.type "^[A-Z_][a-zA-Z0-9_]*"))

(variable_declaration
  (identifier) @feppz.entity.name.type
  (#match? @feppz.entity.name.type "^[A-Z_][a-zA-Z0-9_]*")
  "="
  [
    (struct_declaration)
    (enum_declaration)
    (union_declaration)
    (opaque_declaration)
  ])

; --- Types ---
(parameter
  type: (identifier) @feppz.entity.name.type
  (#match? @feppz.entity.name.type "^[A-Z_][a-zA-Z0-9_]*"))

[
  (builtin_type)
  "anyframe"
  "anyopaque"
] @feppz.keyword.type

; --- Parameters & fields ---
(parameter
  name: (identifier) @feppz.variable)

(payload
  (identifier) @feppz.variable)

; Dotted paths: dvui in dvui.TextureTarget, std/mem in std.mem.Allocator
(field_expression
  object: (identifier) @feppz.variable.namespace
  (#match? @feppz.variable.namespace "^[a-z_][a-zA-Z0-9_]*"))

(field_expression
  (_)
  member: (identifier) @feppz.entity.name.type
  (#match? @feppz.entity.name.type "^[A-Z_][a-zA-Z0-9_]*"))

(field_expression
  (_)
  member: (identifier) @feppz.variable.namespace
  (#match? @feppz.variable.namespace "^[a-z_][a-zA-Z0-9_]*"))

(field_initializer
  .
  (identifier) @feppz.variable.member)

(container_field
  name: (identifier) @feppz.variable.member)

(enum_declaration
  (container_field
    type: (identifier) @feppz.variable.enum_member))

(initializer_list
  (assignment_expression
    left: (field_expression
      .
      member: (identifier) @feppz.variable.namespace
      (#match? @feppz.variable.namespace "^[a-z_][a-zA-Z0-9_]*"))))

(initializer_list
  (assignment_expression
    left: (field_expression
      .
      member: (identifier) @feppz.entity.name.type
      (#match? @feppz.entity.name.type "^[A-Z_][a-zA-Z0-9_]*"))))

; --- Constants ---
((identifier) @feppz.constant
  (#match? @feppz.constant "^[A-Z][A-Z_0-9]+$"))

[
  "null"
  "undefined"
] @feppz.keyword.constant.default

(boolean) @feppz.keyword.constant.bool

; --- Labels ---
(block_label
  (identifier) @feppz.label)

(break_label
  (identifier) @feppz.label)

; --- Builtins & modules ---
(builtin_function
  (builtin_identifier) @feppz.support.function.builtin)

(builtin_identifier) @feppz.support.function.builtin

(call_expression
  function: (builtin_function
    (builtin_identifier) @feppz.support.function.builtin))

(variable_declaration
  (identifier) @feppz.variable.module
  (builtin_function
    (builtin_identifier) @feppz.support.function.builtin
    (#any-of? @feppz.support.function.builtin "@import" "@cImport")))

[
  "c"
  "..."
] @feppz.variable.builtin

((identifier) @feppz.variable.builtin
  (#eq? @feppz.variable.builtin "_"))

(calling_convention
  (identifier) @feppz.variable.builtin)

; --- Keywords (vscode-zig scopes) ---
[
  "const"
  "var"
  "test"
  "and"
  "or"
] @feppz.keyword.default

"fn" @feppz.storage.type.function

[
  "struct"
  "union"
  "enum"
  "opaque"
] @feppz.keyword.structure

[
  "extern"
  "packed"
  "export"
  "pub"
  "noalias"
  "inline"
  "comptime"
  "volatile"
  "align"
  "linksection"
  "threadlocal"
  "allowzero"
  "noinline"
  "callconv"
  "usingnamespace"
  "addrspace"
] @feppz.keyword.storage

"asm" @feppz.keyword.control.flow

"error" @feppz.keyword.control.flow

[
  "break"
  "return"
  "continue"
  "defer"
  "errdefer"
  "unreachable"
] @feppz.keyword.control.flow

[
  "while"
  "for"
] @feppz.keyword.control.flow

[
  "resume"
  "suspend"
  "nosuspend"
  "async"
  "await"
] @feppz.keyword.control.flow

[
  "if"
  "else"
  "switch"
  "orelse"
] @feppz.keyword.control.flow

[
  "try"
  "catch"
] @feppz.keyword.control.flow

; --- Operators ---
[
  "="
  "*="
  "*%="
  "*|="
  "/="
  "%="
  "+="
  "+%="
  "+|="
  "-="
  "-%="
  "-|="
  "<<="
  "<<|="
  ">>="
  "&="
  "^="
  "|="
  "!"
  "~"
  "-"
  "-%"
  "&"
  "=="
  "!="
  ">"
  ">="
  "<="
  "<"
  "^"
  "|"
  "<<"
  ">>"
  "<<|"
  "+"
  "++"
  "+%"
  "-%"
  "+|"
  "-|"
  "*"
  "/"
  "%"
  "**"
  "*%"
  "*|"
  "||"
  ".*"
  ".?"
  "?"
  ".."
] @feppz.operator

; --- Literals ---
(character) @feppz.string.character

([
  (string)
  (multiline_string)
] @feppz.string
  (#set! "priority" 1))

(integer) @feppz.number

(float) @feppz.number.float

(escape_sequence) @feppz.string.escape
  (#set! "priority" 95)

; --- Punctuation ---
["(" ")"] @feppz.punctuation.round

["[" "]"] @feppz.punctuation.square

["{" "}"] @feppz.punctuation.curly

[
  ";"
  ","
  ":"
  "=>"
  "->"
] @feppz.punctuation

"." @feppz.punctuation.accessor

(payload
  "|" @feppz.punctuation.square)

; --- Comments ---
(comment) @feppz.comment @spell

((comment) @feppz.comment.documentation
  (#match? @feppz.comment.documentation "^//!"))

; --- Fallback identifiers (lowest priority) ---
(identifier) @feppz.variable
  (#set! "priority" 0)
