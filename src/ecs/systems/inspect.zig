const std = @import("std");
const zm = @import("zmath");
const ecs = @import("zflecs");
const imgui = @import("zig-imgui");
const game = @import("../../aftersun.zig");
const components = game.components;

pub fn groupBy(world: *ecs.world_t, table: *ecs.table_t, id: ecs.entity_t, ctx: ?*anyopaque) callconv(.C) ecs.entity_t {
    _ = ctx;
    var match: ecs.entity_t = 0;
    if (ecs.search(world, table, ecs.pair(id, ecs.Wildcard), &match) != -1) {
        return ecs.pair_second(match);
    }
    return 0;
}

pub fn system(world: *ecs.world_t) ecs.system_desc_t {
    var desc: ecs.system_desc_t = .{};
    desc.query.filter.terms[0] = .{ .id = ecs.id(components.Player), .inout = .In };
    desc.query.filter.terms[1] = .{ .id = ecs.id(components.Position), .inout = .In };
    desc.run = run;

    var ctx_desc: ecs.query_desc_t = .{};
    ctx_desc.filter.terms[0] = .{ .id = ecs.pair(ecs.id(components.Cell), ecs.Wildcard), .inout = .In };
    ctx_desc.filter.terms[1] = .{ .id = ecs.id(components.Position), .inout = .In };
    ctx_desc.filter.terms[2] = .{ .id = ecs.pair(ecs.id(components.Ignore), ecs.id(components.Inspect)), .oper = ecs.oper_kind_t.Not, .inout = .In };
    ctx_desc.group_by = groupBy;
    ctx_desc.group_by_id = ecs.id(components.Cell);
    desc.ctx = ecs.query_init(world, &ctx_desc) catch unreachable;

    return desc;
}

var inspect_time: f32 = 0.0;
var inspect_target: ecs.entity_t = 0;
var last_width: f32 = 0.0;
var inspect: bool = false;

pub fn run(it: *ecs.iter_t) callconv(.C) void {
    const world = it.world;

    if (game.state.mouse.button(.secondary)) |bt| {
        if (bt.released())
            inspect = !inspect;
    }
    if (game.state.hotkeys.hotkey(.inspect)) |hk| {
        if (hk.up() and !inspect) {
            ecs.enable(world, game.state.entities.selection, false);
            inspect_time = 0.0;
            return;
        }
    }

    while (ecs.iter_next(it)) {
        var i: usize = 0;
        while (i < it.count()) : (i += 1) {
            var counter: u64 = 0;
            var target_entity: ?ecs.entity_t = null;

            const mouse = game.state.mouse.tile();
            var mouse_tile: components.Tile = .{
                .x = mouse[0],
                .y = mouse[1],
            };

            if (ecs.field(it, components.Position, 2)) |player_positions| {
                const player_screen_position = game.state.camera.worldToScreen(zm.f32x4(@floor(player_positions[i].x), @floor(player_positions[i].y + game.settings.pixels_per_unit * 2.0), player_positions[i].z, 0.0));
                mouse_tile.z = player_positions[i].tile.z;

                if (it.ctx) |ctx| {
                    const query = @as(*ecs.query_t, @ptrCast(ctx));
                    var query_it = ecs.query_iter(world, query);

                    if (game.state.cells.get(mouse_tile.toCell())) |cell_entity| {
                        ecs.query_set_group(&query_it, cell_entity);
                    }

                    while (ecs.iter_next(&query_it)) {
                        var j: usize = 0;
                        while (j < query_it.count()) : (j += 1) {
                            if (ecs.field(&query_it, components.Position, 2)) |positions| {
                                if (positions[j].tile.x == mouse_tile.x and positions[j].tile.y == mouse_tile.y and positions[j].tile.z == mouse_tile.z) {
                                    if (positions[j].tile.counter > counter) {
                                        counter = positions[j].tile.counter;
                                        target_entity = query_it.entities()[j];
                                    }
                                }
                            }
                        }
                    }
                }

                if (target_entity) |target| {
                    if (target == inspect_target) {
                        if (inspect_time < 1.0) {
                            inspect_time += it.delta_time * 3.0;
                        } else {
                            inspect_time = 1.0;
                        }
                    } else {
                        inspect_target = target;
                        inspect_time = 0.0;
                    }

                    const target_tile_position = mouse_tile.toPosition(.position).toF32x4();
                    const target_screen_position = game.state.camera.worldToScreen(target_tile_position);

                    if (ecs.get_mut(world, game.state.entities.selection, components.Position)) |position| {
                        const p = mouse_tile.toPosition(.tile);
                        position.x = p.x;
                        position.y = p.y;
                        position.z = player_positions[0].z;
                        position.tile.x = p.tile.x;
                        position.tile.y = p.tile.y;
                        position.tile.z = player_positions[0].tile.z;
                        position.tile.counter = 0;

                        ecs.enable(world, game.state.entities.selection, true);
                    }

                    const examine_text = createExamineText(game.state.allocator, target);
                    defer game.state.allocator.free(examine_text);

                    const index: usize = std.math.clamp(@as(usize, @intFromFloat(@as(f32, @floatFromInt(examine_text.len)) * inspect_time)), 1, examine_text.len);

                    const indexed_text = std.fmt.allocPrintZ(game.state.allocator, "{s}", .{examine_text[0..index]}) catch unreachable;
                    defer game.state.allocator.free(indexed_text);

                    var width = imgui.calcTextSize(indexed_text);

                    if (width.x < last_width)
                        width.x = last_width;

                    const window_pos: imgui.Vec2 = .{ .x = @floor(player_screen_position[0] - width.x / 2.0), .y = @floor(player_screen_position[1]) };
                    var bg_color = game.settings.colors.background;
                    bg_color.value[3] = std.math.clamp(inspect_time * game.settings.colors.background.value[3], 0.0, 1.0);

                    var text_color = game.settings.colors.text;
                    text_color.value[3] = std.math.clamp(inspect_time * game.settings.colors.text.value[3], 0.0, 1.0);

                    imgui.pushStyleColorImVec4(imgui.Col_WindowBg, bg_color.toImguiVec4());
                    imgui.pushStyleColorImVec4(imgui.Col_Text, text_color.toImguiVec4());

                    imgui.setNextWindowPos(window_pos, imgui.Cond_Always);
                    const flags: imgui.WindowFlags = imgui.WindowFlags_AlwaysAutoResize | imgui.WindowFlags_NoDecoration;
                    if (imgui.begin("InspectDialog", null, flags)) {
                        defer imgui.end();

                        last_width = imgui.getWindowWidth();

                        if (imgui.getForegroundDrawList()) |draw_list| {
                            draw_list.pushClipRectFullScreen();
                            defer draw_list.popClipRect();

                            draw_list.addTriangleFilled(
                                .{ .x = @floor(window_pos.x + imgui.getWindowWidth() / 2.0 - 5.0), .y = @floor(window_pos.y + imgui.getWindowHeight() + 0.5) },
                                .{ .x = @floor(window_pos.x + imgui.getWindowWidth() / 2.0), .y = @floor(window_pos.y + imgui.getWindowHeight() + 8.5) },
                                .{ .x = @floor(window_pos.x + 5.0 + imgui.getWindowWidth() / 2.0), .y = @floor(window_pos.y + imgui.getWindowHeight() + 0.5) },
                                bg_color.toU32(),
                            );
                        }
                        imgui.text(indexed_text);
                    }

                    imgui.popStyleColorEx(2);

                    const useable = ecs.has_id(world, target, ecs.id(components.Useable));

                    const show_choice_dialog = useable or target == game.state.entities.player;

                    if (show_choice_dialog) {
                        imgui.pushStyleColorImVec4(imgui.Col_WindowBg, .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 });
                        defer imgui.popStyleColor();

                        imgui.setNextWindowSize(.{ .x = 100, .y = 0.0 }, imgui.Cond_None);
                        imgui.setNextWindowPos(.{ .x = target_screen_position[0] + game.settings.pixels_per_unit / 2.0 * game.state.camera.zoom / 2.0, .y = target_screen_position[1] }, imgui.Cond_Always);
                        if (imgui.begin("ChoiceDialog", null, flags)) {
                            defer imgui.end();

                            if (useable) {
                                if (imgui.buttonEx(if (ecs.has_id(world, target, ecs.id(components.Consumeable))) "Consume" else "Use", .{ .x = -1.0, .y = 0.0 })) {
                                    _ = ecs.set_pair(world, game.state.entities.player, ecs.id(components.Request), ecs.id(components.Use), components.Use, .{ .target = mouse_tile });
                                    inspect = false;
                                }
                                if (imgui.buttonEx("Use with", .{ .x = -1.0, .y = 0.0 })) {
                                    inspect = false;
                                }
                            }

                            if (target == game.state.entities.player) {
                                if (imgui.buttonEx("Change", .{ .x = -1.0, .y = 0.0 })) {
                                    var prng = std.rand.DefaultPrng.init(@as(u64, @intFromFloat(game.state.game_time * 10000)));
                                    const rand = prng.random();

                                    if (ecs.get_mut(world, game.state.entities.player, components.CharacterAnimator)) |animator| {
                                        animator.top_set = if (rand.boolean()) game.animation_sets.top_f_01 else game.animation_sets.top_f_02;
                                        animator.bottom_set = if (rand.boolean()) game.animation_sets.bottom_f_02 else game.animation_sets.bottom_f_01;
                                    }

                                    if (ecs.get_mut(world, game.state.entities.player, components.CharacterRenderer)) |renderer| {
                                        const top = rand.intRangeAtMost(u8, 1, 12);
                                        const bottom = rand.intRangeAtMost(u8, 1, 12);
                                        const hair = rand.intRangeAtMost(u8, 1, 12);

                                        renderer.top_color = game.math.Color.initBytes(top, 0, 0, 255).toSlice();
                                        renderer.bottom_color = game.math.Color.initBytes(bottom, 0, 0, 255).toSlice();
                                        renderer.hair_color = game.math.Color.initBytes(hair, 0, 0, 255).toSlice();
                                    }
                                }
                            }
                        }
                    }
                } else {
                    inspect_time = 0.0;
                    inspect = false;
                    ecs.enable(world, game.state.entities.selection, false);
                }
            }
        }
    }
}

fn orderBy(_: ecs.entity_t, c1: ?*const anyopaque, _: ecs.entity_t, c2: ?*const anyopaque) callconv(.C) c_int {
    const tile_1 = ecs.cast(components.Position, c1);
    const tile_2 = ecs.cast(components.Position, c2);

    return @as(c_int, @intCast(@intFromBool(tile_1.tile.counter > tile_2.tile.counter))) - @as(c_int, @intCast(@intFromBool(tile_1.tile.counter < tile_2.tile.counter)));
}

fn createExamineText(allocator: std.mem.Allocator, target: ecs.entity_t) [:0]u8 {
    const prefab = ecs.get_target(game.state.world, target, ecs.IsA, 0);

    var name = if (prefab != 0) (if (ecs.get_name(game.state.world, prefab)) |n| n else "error") else if (ecs.get_name(game.state.world, target)) |n| n else "error";
    if (target == game.state.entities.player) name = "myself";

    const prefix = "I see";

    const count = if (ecs.get(game.state.world, target, components.Stack)) |stack| stack.count else 1;

    const n = std.mem.span(name);
    var buffer: [128]u8 = undefined;
    _ = std.mem.replace(u8, n, "_", " ", &buffer);
    const fixed_name = buffer[0..n.len];

    if (count > 1) {
        return std.fmt.allocPrintZ(allocator, "{s} {d} {s}s.", .{ prefix, count, fixed_name }) catch unreachable;
    } else {
        if (target != game.state.entities.player) {
            const quantifier = switch (name[0]) {
                'a', 'e', 'i', 'o', 'u' => "an",
                else => "a",
            };

            return std.fmt.allocPrintZ(game.state.allocator, "{s} {s} {s}.", .{ prefix, quantifier, fixed_name }) catch unreachable;
        } else {
            return std.fmt.allocPrintZ(game.state.allocator, "{s} {s}.", .{ prefix, fixed_name }) catch unreachable;
        }
    }
}
