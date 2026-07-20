//! Schema-driven half of the Settings sidebar (see `Editor.drawSettingsPane`).
//!
//! Plugins register a typed settings value + field metadata (`sdk.settings.SettingsSchema`);
//! **this pane draws all controls** so every plugin's settings share the same appearance.
//! Plugins do not supply a `draw` callback.
//!
//! Loaded-only: disabled plugins get an Enabled toggle only; failed plugins show the reason.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const PluginStore = @import("PluginStore.zig");
const settings = fizzy.sdk.settings;

pub fn draw() !void {
    const editor = fizzy.editor;
    const host = &editor.host;

    for (host.settings_schemas.items) |*schema| try drawLoaded(schema);
    for (editor.disabled_plugin_ids.items) |id| drawDisabled(id);
    for (editor.failed_user_plugins.items) |f| drawFailed(f);
}

/// Loaded / disabled / failed are drawn from three independent lists that can legitimately
/// contain the same plugin id at once (e.g. a built-in's own dylib rediscovered in the shared
/// user plugins directory used to show up as both loaded *and* failed — see `loadUserPlugins`).
/// Each section gets its own hash seed so an id shared across sections can never collide on the
/// same heading widget id — same story dvui's own "duplicate widget id" hint points at, just
/// scoped per section instead of per loop index.
const Section = enum(u64) { loaded = 0, disabled = 1, failed = 2 };

fn hashId(section: Section, s: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(@intFromEnum(section), s));
}

fn drawHeading(text: []const u8, id_extra: usize) void {
    dvui.labelNoFmt(@src(), text, .{}, .{
        .id_extra = id_extra,
        .font = dvui.Font.theme(.heading),
        .margin = .{ .x = 2, .y = 12, .w = 2, .h = 2 },
    });
}

fn drawLoaded(schema: *const settings.SettingsSchema) !void {
    const title = if (schema.title.len > 0) schema.title else schema.owner.display_name;
    const id_extra = hashId(.loaded, schema.owner.id);
    drawHeading(title, id_extra);

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
    });
    defer box.deinit();

    for (schema.fields, 0..) |field, fi| {
        try drawField(schema, field, fi, id_extra +% fi +% 1);
    }
}

fn drawField(schema: *const settings.SettingsSchema, field: settings.Setting, field_index: usize, id_extra: usize) !void {
    const access = schema.access;
    const value = schema.value;

    switch (field.kind) {
        .bool => {
            var b = access.getBool(value, field_index);
            if (dvui.checkbox(@src(), &b, field.label, .{ .id_extra = id_extra, .expand = .none })) {
                access.setBool(value, field_index, b);
                access.persist(value, schema.owner);
            }
        },
        .int => |int_kind| {
            if (int_kind.choices.len > 0) {
                try drawIntChoices(schema, field, int_kind.choices, field_index, id_extra);
            } else {
                dvui.label(@src(), "{s}", .{field.label}, .{ .id_extra = id_extra });
                var as_f: f32 = @floatFromInt(access.getInt(value, field_index));
                const min_f: f32 = @floatFromInt(int_kind.min);
                const max_f: f32 = @floatFromInt(int_kind.max);
                if (dvui.sliderEntry(@src(), "{d:0.0}", .{
                    .value = &as_f,
                    .interval = 1.0,
                    .min = min_f,
                    .max = max_f,
                }, .{
                    .id_extra = id_extra +% 1,
                    .expand = .horizontal,
                })) {
                    access.setInt(value, field_index, @intFromFloat(as_f));
                    access.persist(value, schema.owner);
                }
            }
        },
        .float => |float_kind| {
            dvui.label(@src(), "{s}", .{field.label}, .{ .id_extra = id_extra });
            var as_f: f32 = @floatCast(access.getFloat(value, field_index));
            if (dvui.sliderEntry(@src(), "{d:0.2}", .{
                .value = &as_f,
                .interval = @floatCast(float_kind.step),
                .min = @floatCast(float_kind.min),
                .max = @floatCast(float_kind.max),
            }, .{
                .id_extra = id_extra +% 1,
                .expand = .horizontal,
            })) {
                access.setFloat(value, field_index, as_f);
                access.persist(value, schema.owner);
            }
        },
        .enumeration => |enum_kind| {
            const choices = enum_kind.choices;
            var dropdown: dvui.DropdownWidget = undefined;
            dropdown.init(@src(), .{ .label = field.label }, .{
                .id_extra = id_extra,
                .expand = .horizontal,
                .corners = dvui.CornerRect.all(1000),
            });
            defer dropdown.deinit();

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .vertical,
                .gravity_x = 1.0,
            });
            const idx = access.getEnumIndex(value, field_index);
            const current = if (idx < choices.len) choices[idx] else "?";
            dvui.label(@src(), "{s}", .{current}, .{ .margin = .all(0), .padding = .all(0) });
            dvui.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });
            hbox.deinit();

            if (dropdown.dropped()) {
                for (choices, 0..) |choice, ci| {
                    if (dropdown.addChoiceLabel(choice)) {
                        access.setEnumIndex(value, field_index, ci);
                        access.persist(value, schema.owner);
                    }
                }
            }
        },
        .string => {
            // Read-only until setString owns allocation policy.
            const s = access.getString(value, field_index);
            dvui.label(@src(), "{s}: {s}", .{ field.label, s }, .{ .id_extra = id_extra });
        },
        .color => {
            dvui.label(@src(), "{s}: (color picker TBD)", .{field.label}, .{ .id_extra = id_extra });
        },
    }
}

fn drawIntChoices(schema: *const settings.SettingsSchema, field: settings.Setting, choices: []const i64, field_index: usize, id_extra: usize) !void {
    const access = schema.access;
    const value = schema.value;
    const current = access.getInt(value, field_index);

    var dropdown: dvui.DropdownWidget = undefined;
    dropdown.init(@src(), .{ .label = field.label }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .corners = dvui.CornerRect.all(1000),
    });
    defer dropdown.deinit();

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .vertical,
        .gravity_x = 1.0,
    });
    const label_text = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{current}) catch "?";
    dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });
    dvui.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });
    hbox.deinit();

    if (dropdown.dropped()) {
        for (choices) |choice| {
            const choice_label = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{choice}) catch continue;
            if (dropdown.addChoiceLabel(choice_label)) {
                access.setInt(value, field_index, choice);
                access.persist(value, schema.owner);
            }
        }
    }
}

fn drawDisabled(id: []const u8) void {
    const id_extra = hashId(.disabled, id);
    drawHeading(PluginStore.displayName(id), id_extra);

    var enabled = false;
    if (dvui.checkbox(@src(), &enabled, "Enabled", .{ .id_extra = id_extra })) {
        PluginStore.queueSetEnabled(id, enabled);
    }
}

fn drawFailed(f: fizzy.Editor.FailedPlugin) void {
    const id_extra = hashId(.failed, f.id);
    drawHeading(PluginStore.displayName(f.id), id_extra);

    var buf: [256]u8 = undefined;
    const text = if (f.detail) |d|
        std.fmt.bufPrint(&buf, "Failed to load: {s} ({s})", .{ f.reason, d }) catch f.reason
    else
        std.fmt.bufPrint(&buf, "Failed to load: {s}", .{f.reason}) catch f.reason;

    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = false,
    });
    tl.addText(text, .{ .color_text = dvui.themeGet().color(.err, .text) });
    tl.deinit();
}
