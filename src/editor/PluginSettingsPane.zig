//! Draws a single plugin settings control.
//!
//! Plugins register a typed settings value + field metadata (`sdk.settings.SettingsSchema`);
//! **this file draws all controls** so every plugin's settings share the same appearance.
//! Plugins do not supply a `draw` callback.
//!
//! Which controls appear, and where, is `SettingsTree`'s decision — it owns the Settings pane,
//! draws each field's label (with search highlighting), and calls `drawField` for the control
//! body only. Loaded-with-settings-only still holds: a plugin gets rows only if it registered a
//! schema. Enabling/disabling a plugin is the Plugins store tab's job (`PluginStore.zig`), never
//! this one's.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const wdvui = core.dvui;
const fizzy = @import("../fizzy.zig");
const settings = fizzy.sdk.settings;

/// Draw the control for `field` — no label. `SettingsTree` draws the setting name above this.
pub fn drawField(schema: *const settings.SettingsSchema, field: settings.Setting, field_index: usize, id_extra: usize) !void {
    const access = schema.access;
    const value = schema.value;

    switch (field.kind) {
        .bool => {
            var b = access.getBool(value, field_index);
            if (wdvui.toggle(@src(), &b, .{ .id_extra = id_extra })) {
                access.setBool(value, field_index, b);
                access.persist(value, schema.owner);
            }
        },
        .int => |int_kind| {
            if (int_kind.choices.len > 0) {
                try drawIntChoices(schema, field, int_kind.choices, field_index, id_extra);
            } else {
                var as_f: f32 = @floatFromInt(access.getInt(value, field_index));
                const min_f: f32 = @floatFromInt(int_kind.min);
                const max_f: f32 = @floatFromInt(int_kind.max);
                if (dvui.sliderEntry(@src(), "{d:0.0}", .{
                    .value = &as_f,
                    .interval = 1.0,
                    .min = min_f,
                    .max = max_f,
                }, .{
                    .id_extra = id_extra,
                    .expand = .horizontal,
                })) {
                    access.setInt(value, field_index, @intFromFloat(as_f));
                    access.persist(value, schema.owner);
                }
            }
        },
        .float => |float_kind| {
            var as_f: f32 = @floatCast(access.getFloat(value, field_index));
            if (dvui.sliderEntry(@src(), "{d:0.2}", .{
                .value = &as_f,
                .interval = @floatCast(float_kind.step),
                .min = @floatCast(float_kind.min),
                .max = @floatCast(float_kind.max),
            }, .{
                .id_extra = id_extra,
                .expand = .horizontal,
            })) {
                access.setFloat(value, field_index, as_f);
                access.persist(value, schema.owner);
            }
        },
        .enumeration => |enum_kind| {
            const choices = enum_kind.choices;
            var dropdown: dvui.DropdownWidget = undefined;
            dropdown.init(@src(), .{}, .{
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
        .string => try drawString(schema, field_index, id_extra),
        .color => {
            dvui.label(@src(), "(color picker TBD)", .{}, .{ .id_extra = id_extra });
        },
    }
}

/// Text entry for a `[]const u8` setting. Committed on Enter only — the entry re-seeds itself
/// from the live value whenever it isn't focused, so an abandoned edit reverts on blur and an
/// external change (a hand-edit reconciled by `SettingsWatcher`) shows up here without the pane
/// needing its own change notification. `Access.setString` copies the bytes into schema-owned
/// storage, so nothing here has to outlive the frame.
fn drawString(schema: *const settings.SettingsSchema, field_index: usize, id_extra: usize) !void {
    const access = schema.access;
    const value = schema.value;
    const current = access.getString(value, field_index);

    var entry: dvui.TextEntryWidget = undefined;
    entry.init(@src(), .{}, .{ .id_extra = id_extra, .expand = .horizontal });
    const focused = dvui.focusedWidgetId() == entry.data().id;
    if (!focused and !std.mem.eql(u8, entry.getText(), current)) entry.textSet(current, false);
    entry.processEvents();
    entry.draw();
    if (entry.enter_pressed and !std.mem.eql(u8, entry.getText(), current)) {
        access.setString(value, field_index, entry.getText());
        access.persist(value, schema.owner);
    }
    entry.deinit();
}

fn drawIntChoices(schema: *const settings.SettingsSchema, field: settings.Setting, choices: []const i64, field_index: usize, id_extra: usize) !void {
    _ = field;
    const access = schema.access;
    const value = schema.value;
    const current = access.getInt(value, field_index);

    var dropdown: dvui.DropdownWidget = undefined;
    dropdown.init(@src(), .{}, .{
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
