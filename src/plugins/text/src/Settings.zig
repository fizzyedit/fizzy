//! Text plugin's user-facing settings — indentation for now. First plugin in the tree to use
//! `Host.loadPluginSettings`/`storePluginSettings` (previously unused by any plugin), so this
//! also establishes the pattern: load once at `register()`, save on change via a small helper
//! that stringifies just the persisted fields and hands the JSON blob to the host.
const std = @import("std");
const internal = @import("../text.zig");
const sdk = internal.sdk;
const dvui = internal.dvui;
const State = internal.State;
const plugin_mod = internal.plugin;

/// On-disk shape, persisted under `settings.json`'s `"plugins"."text"` key. Kept separate
/// from `State` (which also holds unrelated runtime state like the open-document registry)
/// so this stays a stable, minimal, forward-compatible schema on its own.
const Persisted = struct {
    insert_spaces_on_tab: bool = true,
    tab_size: u8 = 4,
    format_on_save: bool = false,
};

/// Loads persisted settings (if any) into `st`. Call once from `register()`, before the
/// settings section is registered — a missing/unparseable blob just keeps `State`'s defaults.
pub fn load(host: *sdk.Host, st: *State) void {
    const json = host.loadPluginSettings("text") orelse return;
    const parsed = std.json.parseFromSlice(Persisted, sdk.allocator(), json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        dvui.log.warn("text: failed to parse persisted settings: {any}", .{err});
        return;
    };
    defer parsed.deinit();
    st.insert_spaces_on_tab = parsed.value.insert_spaces_on_tab;
    st.tab_size = parsed.value.tab_size;
    st.format_on_save = parsed.value.format_on_save;
}

fn save(st: *State) void {
    const gpa = sdk.allocator();
    const persisted: Persisted = .{
        .insert_spaces_on_tab = st.insert_spaces_on_tab,
        .tab_size = st.tab_size,
        .format_on_save = st.format_on_save,
    };
    const json = std.json.Stringify.valueAlloc(gpa, persisted, .{}) catch |err| {
        dvui.log.warn("text: failed to serialize settings: {any}", .{err});
        return;
    };
    defer gpa.free(json);
    sdk.host().storePluginSettings("text", json) catch |err| {
        dvui.log.warn("text: failed to store settings: {any}", .{err});
    };
}

pub fn registerSection(host: *sdk.Host, st: *State) !void {
    try host.registerSettingsSection(.{
        .id = "text.settings",
        .owner = plugin_mod.pluginPtr(),
        .title = "Text Editor",
        .ctx = @ptrCast(st),
        .draw = drawTextSettings,
    });
}

fn drawTextSettings(ctx: ?*anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(ctx orelse return));

    var box = dvui.groupBox(@src(), "Indentation", .{ .expand = .horizontal });
    defer box.deinit();

    if (dvui.checkbox(@src(), &st.insert_spaces_on_tab, "Insert spaces on Tab", .{
        .expand = .none,
    })) {
        save(st);
    }

    {
        var dropdown: dvui.DropdownWidget = undefined;
        dropdown.init(@src(), .{ .label = "Tab width" }, .{
            .expand = .horizontal,
            .corners = dvui.CornerRect.all(1000),
        });
        defer dropdown.deinit();

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .vertical,
            .gravity_x = 1.0,
        });

        const label_text = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{st.tab_size}) catch "4";
        dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });
        dvui.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

        hbox.deinit();

        if (dropdown.dropped()) {
            inline for (.{ 2, 4, 8 }) |width| {
                if (dropdown.addChoiceLabel(std.fmt.comptimePrint("{d}", .{width}))) {
                    st.tab_size = width;
                    save(st);
                }
            }
        }
    }

    var format_box = dvui.groupBox(@src(), "Formatting", .{ .expand = .horizontal });
    defer format_box.deinit();

    if (dvui.checkbox(@src(), &st.format_on_save, "Format on Save", .{
        .expand = .none,
    })) {
        save(st);
    }
}
