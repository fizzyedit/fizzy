//! Server-agnostic LSP client, shared by every language plugin (`zig`/zls, a future
//! `cpp`/clangd, `csharp`/omnisharp, …) so writing a new one doesn't mean re-implementing
//! JSON-RPC framing, request/response caching, and threading discipline from scratch. A
//! language plugin supplies a `Client.Config` (server command, `languageId`, host callbacks)
//! and gets hover/goto-definition/completion/signature-help/format for free.
pub const Client = @import("Client.zig");
pub const Protocol = @import("Protocol.zig");
pub const UriUtil = @import("UriUtil.zig");

pub const HoverResult = Client.HoverResult;
pub const DefinitionLocation = Client.DefinitionLocation;
pub const CompletionKind = Client.CompletionKind;
pub const CompletionItem = Client.CompletionItem;
pub const SignatureHelpResult = Client.SignatureHelpResult;
