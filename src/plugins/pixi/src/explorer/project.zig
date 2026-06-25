const std = @import("std");
const builtin = @import("builtin");
const icons = @import("icons");

const dvui = @import("dvui");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");
const PackProject = @import("../pack_project.zig");

pub fn draw() !void {
    // On web there's no project folder concept. Render a simplified pane that
    // only exposes the Pack button (operates on currently-open files via
    // `startPackProject`'s wasm path). Native flow below assumes a folder.
    if (comptime builtin.target.cpu.arch == .wasm32) {
        try drawWeb();
        return;
    }

    if (runtime.state().host.folder()) |folder| {
        if (runtime.state().project) |_| {
            const tl = dvui.textLayout(@src(), .{}, .{
                .expand = .none,
                .margin = dvui.Rect.all(0),
                .background = false,
            });
            defer tl.deinit();

            const project_path = std.fs.path.join(dvui.currentWindow().lifo(), &.{ folder, ".fizproject" }) catch {
                dvui.log.err("Failed to join project path", .{});
                return;
            };
            defer dvui.currentWindow().lifo().free(project_path);

            tl.addText(project_path, .{ .color_text = dvui.themeGet().color(.control, .text) });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 } });
        } else {
            var box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .max_size_content = .{ .w = runtime.state().host.explorerVirtualSize().w, .h = std.math.floatMax(f32) },
            });
            defer box.deinit();

            const tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
            tl.addText("No project file found!\n\n", .{});
            tl.addText("Would you like to create a project file to specify constant output paths and other project-specific behaviors?\n", .{ .color_text = dvui.themeGet().color(.control, .text) });
            tl.deinit();

            if (dvui.button(@src(), "Create Project", .{}, .{ .expand = .horizontal })) {
                runtime.state().project = .{};
            }
            return;
        }

        const packing = PackProject.isActive(runtime.state());
        if (packProjectButton(packing)) {
            PackProject.start(runtime.state()) catch |err| {
                dvui.log.err("Failed to start project pack: {any}", .{err});
            };
        }

        if (runtime.packer().atlas != null) {
            drawPackedAtlasStats();
        }

        pathTextEntry(.atlas) catch {
            dvui.log.err("Failed to draw path text entry", .{});
        };
        pathTextEntry(.image) catch {
            dvui.log.err("Failed to draw path text entry", .{});
        };

        if (runtime.state().project) |project| {
            if (runtime.packer().atlas) |atlas| {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 } });
                if (dvui.button(@src(), "Export Project", .{ .draw_focus = false }, .{
                    .expand = .horizontal,
                    .style = .highlight,
                })) {
                    if (project.packed_atlas_output) |output| {
                        atlas.save(output, .data) catch {
                            dvui.log.err("Failed to save atlas data", .{});
                        };
                    }

                    if (project.packed_image_output) |image_output| {
                        atlas.save(image_output, .source) catch {
                            dvui.log.err("Failed to save atlas image", .{});
                        };
                    }
                }
            }
        }
    }

    // {
    //     var set_text: bool = false;
    //     dvui.labelNoFmt(@src(), "Atlas Data Output:", .{}, .{});

    //     var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    //     defer box.deinit();

    //     if (dvui.buttonIcon(@src(), "example.atlas", icons.tvg.lucide.@"folder-open", .{}, .{
    //         .fill_color = .fromTheme(.text_press),
    //     }, .{
    //         .gravity_y = 0.5,
    //         .padding = dvui.Rect.all(4),
    //         .border = dvui.Rect.all(1),
    //         .margin = .{ .x = 1, .w = 1 },
    //     })) {
    //         const valid_path: bool = blk: {
    //             if (project.packed_atlas_output) |output| {
    //                 const base_name = std.fs.path.basename(output);
    //                 if (std.mem.indexOf(u8, output, base_name)) |i| {
    //                     if (!std.fs.path.isAbsolute(output[0..i])) {
    //                         break :blk false;
    //                     }

    //                     std.Io.Dir.accessAbsolute(dvui.io, output[0..i], .{}) catch {
    //                         break :blk false;
    //                     };
    //                 } else {
    //                     if (!std.fs.path.isAbsolute(output)) {
    //                         break :blk false;
    //                     }
    //                     std.Io.Dir.accessAbsolute(dvui.io, output, .{}) catch {
    //                         break :blk false;
    //                     };
    //                 }
    //             }

    //             break :blk true;
    //         };

    //         if (dvui.dialogNativeFileSave(runtime.allocator(), .{
    //             .title = "Select Atlas Data Output",
    //             .filters = &.{".atlas"},
    //             .filter_description = "Atlas file",
    //             .path = if (valid_path) project.packed_atlas_output else null,
    //         }) catch null) |path| {
    //             project.packed_atlas_output = runtime.allocator().dupe(u8, path[0..]) catch null;
    //             set_text = true;
    //         } else {
    //             dvui.log.err("Project failed to copy new path", .{});
    //         }
    //     }

    //     const te = dvui.textEntry(@src(), .{
    //         .placeholder = "example.atlas",
    //     }, .{
    //         .padding = dvui.Rect.all(5),
    //         .expand = .horizontal,
    //         .margin = dvui.Rect.all(0),
    //         .color_text = if (project.packed_atlas_output) |_| .text else .text_press,
    //     });

    //     defer te.deinit();

    //     if (project.packed_atlas_output) |packed_atlas_output| {
    //         if (dvui.firstFrame(te.data().id) or set_text) {
    //             te.textSet(packed_atlas_output, false);
    //         }
    //     }

    //     if (te.text_changed) {
    //         const t = te.getText();
    //         if (t.len > 0) {
    //             project.packed_atlas_output = runtime.allocator().dupe(u8, t) catch null;
    //         } else {
    //             project.packed_atlas_output = null;
    //         }
    //     }
    // }

    // _ = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .h = 10 } });

    // {
    //     var set_text: bool = false;
    //     dvui.labelNoFmt(@src(), "Atlas Image Output:", .{}, .{});

    //     var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    //     defer box.deinit();

    //     if (dvui.buttonIcon(@src(), "example.atlas", icons.tvg.lucide.@"folder-open", .{}, .{
    //         .fill_color = .fromTheme(.text_press),
    //     }, .{
    //         .gravity_y = 0.5,
    //         .padding = dvui.Rect.all(4),
    //         .border = dvui.Rect.all(1),
    //         .margin = .{ .x = 1, .w = 1 },
    //     })) {
    //         const valid_path: bool = blk: {
    //             if (project.packed_image_output) |output| {
    //                 const base_name = std.fs.path.basename(output);
    //                 if (std.mem.indexOf(u8, output, base_name)) |i| {
    //                     if (!std.fs.path.isAbsolute(output[0..i])) {
    //                         break :blk false;
    //                     }

    //                     std.Io.Dir.accessAbsolute(dvui.io, output[0..i], .{}) catch {
    //                         break :blk false;
    //                     };
    //                 } else {
    //                     if (!std.fs.path.isAbsolute(output)) {
    //                         break :blk false;
    //                     }
    //                     std.Io.Dir.accessAbsolute(dvui.io, output, .{}) catch {
    //                         break :blk false;
    //                     };
    //                 }
    //             }

    //             break :blk true;
    //         };

    //         if (dvui.dialogNativeFileSave(runtime.allocator(), .{
    //             .title = "Select Atlas Image Output",
    //             .filters = &.{".png"},
    //             .filter_description = "Image file",
    //             .path = if (valid_path) project.packed_image_output else null,
    //         }) catch null) |path| {
    //             project.packed_image_output = runtime.allocator().dupe(u8, path[0..]) catch null;
    //             set_text = true;
    //         } else {
    //             dvui.log.err("Project failed to copy new path", .{});
    //         }
    //     }

    //     const te = dvui.textEntry(@src(), .{
    //         .placeholder = "example.png",
    //     }, .{
    //         .padding = dvui.Rect.all(5),
    //         .expand = .horizontal,
    //         .margin = dvui.Rect.all(0),
    //         .color_text = if (project.packed_image_output) |_| .text else .text_press,
    //     });

    //     defer te.deinit();

    //     if (project.packed_image_output) |packed_image_output| {
    //         if (dvui.firstFrame(te.data().id) or set_text) {
    //             te.textSet(packed_image_output, false);
    //         }
    //     }

    //     if (te.text_changed) {
    //         const t = te.getText();
    //         if (t.len > 0) {
    //             project.packed_image_output = runtime.allocator().dupe(u8, t) catch null;
    //         } else {
    //             project.packed_image_output = null;
    //         }
    //     }
    // }

}

const PathType = enum {
    atlas,
    image,
};

fn pathTextEntry(path_type: PathType) !void {
    if (runtime.state().project) |*project| {
        const output_path = switch (path_type) {
            .atlas => &project.packed_atlas_output,
            .image => &project.packed_image_output,
        };

        const index: usize = switch (path_type) {
            .atlas => 0,
            .image => 1,
        };

        defer _ = dvui.spacer(@src(), .{ .id_extra = index });

        const label_text = switch (path_type) {
            .atlas => "Atlas Data Output:",
            .image => "Atlas Image Output:",
        };

        var set_text: bool = false;
        dvui.labelNoFmt(@src(), label_text, .{}, .{
            .id_extra = index,
        });

        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = index });
        defer box.deinit();

        if (dvui.buttonIcon(@src(), "example.atlas", icons.tvg.lucide.@"folder-open", .{}, .{}, .{
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(4),
            .border = dvui.Rect.all(1),
            .margin = .{ .x = 1, .w = 1 },
            .id_extra = index,
        })) {
            const valid_path: bool = blk: {
                if (output_path.*) |output| {
                    const base_name = std.fs.path.basename(output);
                    if (std.mem.indexOf(u8, output, base_name)) |i| {
                        if (!std.fs.path.isAbsolute(output[0..i])) {
                            break :blk false;
                        }

                        std.Io.Dir.accessAbsolute(dvui.io, output[0..i], .{}) catch {
                            break :blk false;
                        };
                    } else {
                        if (!std.fs.path.isAbsolute(output)) {
                            break :blk false;
                        }
                        std.Io.Dir.accessAbsolute(dvui.io, output, .{}) catch {
                            break :blk false;
                        };
                    }
                }

                break :blk true;
            };

            runtime.state().host.showSaveDialog(if (path_type == .atlas) packedAtlasOutputCallback else packedImageOutputCallback, &.{
                if (path_type == .atlas) .{ .name = "Atlas Data", .pattern = "atlas" } else .{ .name = "Atlas Image", .pattern = "png;jpg;jpeg" },
            }, "", if (valid_path) output_path.* else null);
            set_text = true;
        }

        const te = dvui.textEntry(@src(), .{
            .placeholder = "example.atlas",
        }, .{
            .padding = dvui.Rect.all(5),
            .expand = .horizontal,
            .margin = dvui.Rect.all(0),
            .color_text = if (output_path.*) |_| dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
            .id_extra = index,
        });

        defer te.deinit();

        if (output_path.*) |packed_atlas_output| {
            if (dvui.firstFrame(te.data().id) or dvui.focusedWidgetId() != te.data().id) {
                te.textSet(packed_atlas_output, false);
            }
        }

        if (te.text_changed) {
            const t = te.getText();
            if (t.len > 0) {
                output_path.* = runtime.allocator().dupe(u8, t) catch null;
            } else {
                output_path.* = null;
            }
        }
    }
}

fn drawPackedAtlasStats() void {
    const atlas = &runtime.packer().atlas.?;
    const image_size = pixi_mod.image.size(atlas.source);
    const atlas_w: u32 = @intFromFloat(image_size.w);
    const atlas_h: u32 = @intFromFloat(image_size.h);

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 } });

    const tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .margin = dvui.Rect.all(0),
        .background = false,
    });
    defer tl.deinit();

    const body = dvui.Font.theme(.body);
    const label_color = dvui.themeGet().color(.window, .text);
    const value_color = dvui.themeGet().color(.control, .text);
    const label_opts: dvui.Options = .{ .font = body, .color_text = label_color };
    const value_opts: dvui.Options = .{ .font = body, .color_text = value_color };

    if (runtime.packer().last_packed_at_ns) |packed_at_ns| {
        var when_buf: [64]u8 = undefined;
        const when = formatLastPacked(&when_buf, packed_at_ns);
        tl.addText("Last packed: ", label_opts);
        tl.addText(when, value_opts);
        tl.addText("\n", value_opts);
    }

    var value_buf: [48]u8 = undefined;
    const sprites = std.fmt.bufPrint(&value_buf, "{d}", .{atlas.data.sprites.len}) catch "0";
    tl.addText("Sprites: ", label_opts);
    tl.addText(sprites, value_opts);
    tl.addText("\n", value_opts);

    const animations = std.fmt.bufPrint(&value_buf, "{d}", .{atlas.data.animations.len}) catch "0";
    tl.addText("Animations: ", label_opts);
    tl.addText(animations, value_opts);
    tl.addText("\n", value_opts);

    const atlas_size = std.fmt.bufPrint(&value_buf, "{d} px x {d} px", .{ atlas_w, atlas_h }) catch "0 px x 0 px";
    tl.addText("Atlas size: ", label_opts);
    tl.addText(atlas_size, value_opts);
}

fn formatLastPacked(buf: []u8, packed_at_ns: i128) []const u8 {
    const elapsed_s = @divTrunc(pixi_mod.perf.nanoTimestamp() - packed_at_ns, std.time.ns_per_s);
    if (elapsed_s < 10) {
        return std.fmt.bufPrint(buf, "just now", .{}) catch "recently";
    }
    if (elapsed_s < 60) {
        return std.fmt.bufPrint(buf, "{d}s ago", .{elapsed_s}) catch "recently";
    }
    const elapsed_min = @divTrunc(elapsed_s, 60);
    if (elapsed_min < 60) {
        return std.fmt.bufPrint(buf, "{d} min ago", .{elapsed_min}) catch "recently";
    }
    const elapsed_hr = @divTrunc(elapsed_min, 60);
    if (elapsed_hr < 48) {
        return std.fmt.bufPrint(buf, "{d} hr ago", .{elapsed_hr}) catch "recently";
    }
    const elapsed_day = @divTrunc(elapsed_hr, 24);
    return std.fmt.bufPrint(buf, "{d} days ago", .{elapsed_day}) catch "recently";
}

/// "Pack Project" button. Same look-and-feel as `dvui.button`, but with a bubble spinner
/// pinned to the right edge while a pack is in flight. Always interactive — rapid clicks /
/// per-save repack triggers coalesce via `Editor.startPackProject` cancelling predecessors.
fn packProjectButton(packing: bool) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .expand = .horizontal,
        .style = .highlight,
    });
    defer bw.deinit();

    bw.processEvents();
    bw.drawBackground();
    const clicked = bw.clicked();

    // Center label across the full button rect via gravity. Mirrors `dvui.button`'s call
    // signature so the text picks up the same hovered/pressed colors.
    const label_text: []const u8 = if (packing) "Packing…" else "Pack Project";
    const content_opts = (dvui.Options{}).strip().override(bw.style()).override(.{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    dvui.labelNoFmt(@src(), label_text, .{ .align_x = 0.5, .align_y = 0.5 }, content_opts);

    // Spinner overlays at the right edge — same content rect as the label, but anchored to
    // `gravity_x = 1.0`. Sized to roughly match the cap height so it doesn't fight the label.
    if (packing) {
        pixi_mod.core.dvui.bubbleSpinner(@src(), (dvui.Options{}).strip().override(bw.style()).override(.{
            .min_size_content = .{ .w = 16, .h = 16 },
            .gravity_x = 1.0,
            .gravity_y = 0.5,
            .padding = .{ .w = 4 },
        }), .{});
    }

    bw.drawFocus();
    return clicked;
}

pub fn packedAtlasOutputCallback(paths: ?[][:0]const u8) void {
    if (runtime.state().project) |*project| {
        const output_path = &project.packed_atlas_output;

        if (paths) |paths_| {
            for (paths_) |path| {
                output_path.* = runtime.allocator().dupe(u8, path) catch null;
            }
        }
    }
}

pub fn packedImageOutputCallback(paths: ?[][:0]const u8) void {
    if (runtime.state().project) |*project| {
        const output_path = &project.packed_image_output;

        if (paths) |paths_| {
            for (paths_) |path| {
                output_path.* = runtime.allocator().dupe(u8, path) catch null;
            }
        }
    }
}

/// Wasm-specific simplified pack pane. No folder, no `.fizproject` UI — just
/// the Pack button (operates on currently-open files) and Download buttons for
/// the resulting atlas/image data.
fn drawWeb() !void {
    if (runtime.state().host.openDocCount() == 0) {
        dvui.labelNoFmt(
            @src(),
            "Open one or more files to pack.",
            .{},
            .{ .color_text = dvui.themeGet().color(.control, .text) },
        );
        return;
    }

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer vbox.deinit();

    const btn_opts = dvui.Options{
        .expand = .horizontal,
        .style = .highlight,
    };

    const packing = PackProject.isActive(runtime.state());
    if (packProjectButton(packing)) {
        PackProject.start(runtime.state()) catch |err| {
            dvui.log.err("Failed to pack open files: {any}", .{err});
        };
    }

    if (runtime.packer().atlas != null) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 } });
        drawPackedAtlasStats();
    }

    if (runtime.packer().atlas) |atlas| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 } });
        if (dvui.button(@src(), "Download Atlas JSON", .{ .draw_focus = false }, btn_opts)) {
            atlas.save("atlas.atlas", .data) catch {
                dvui.log.err("Failed to download atlas data", .{});
            };
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 } });
        if (dvui.button(@src(), "Download Atlas PNG", .{ .draw_focus = false }, btn_opts)) {
            atlas.save("atlas.png", .source) catch {
                dvui.log.err("Failed to download atlas image", .{});
            };
        }
    }
}
