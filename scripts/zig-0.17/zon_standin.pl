# ZIG017 stand-in: 0.16 std.zon.parse calls on 0.17's API, results in the given allocator. Replaced by the zon arena PR.
use strict; use warnings;
local $/; 
our $NEED_DUPE = 0;
my $DUPE = <<'ZIGDUPE';

// ZIG017 stand-in: a deep copy of a zon result out of the parse's arena into the caller's
// allocator, where the code before 0.17 expects to free it. Goes with the zon arena PR.
fn zig017ZonDupe(comptime T: type, gpa: std.mem.Allocator, value: T) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => {
                const out = try gpa.create(p.child);
                out.* = try zig017ZonDupe(p.child, gpa, value.*);
                return out;
            },
            .slice => {
                const out = if (comptime p.sentinel()) |s| try gpa.allocSentinel(p.child, value.len, s) else try gpa.alloc(p.child, value.len);
                for (out, value) |*o, v| o.* = try zig017ZonDupe(p.child, gpa, v);
                return out;
            },
            else => comptime unreachable,
        },
        .array => |a| {
            var out: T = undefined;
            for (&out, value) |*o, v| o.* = try zig017ZonDupe(a.child, gpa, v);
            return out;
        },
        .@"struct" => |s| {
            var out: T = value;
            inline for (s.field_names, s.field_types, s.field_attrs) |n, FT, attrs| {
                if (!attrs.@"comptime") @field(out, n) = try zig017ZonDupe(FT, gpa, @field(value, n));
            }
            return out;
        },
        .@"union" => |u| if (u.tag_type == null) return value else switch (value) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try zig017ZonDupe(@TypeOf(payload), gpa, payload)),
        },
        .optional => |o| return if (value) |v| try zig017ZonDupe(o.child, gpa, v) else null,
        else => return value,
    }
}
ZIGDUPE
my $FREE = <<'ZIGFREE';
// ZIG017 stand-in: 0.16's `std.zon.parse.free`, which 0.17 removed (results now come from an
// arena the caller owns). Goes with the zon arena PR.
fn zig017ZonFree(gpa: std.mem.Allocator, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |p| switch (p.size) {
            .one => {
                zig017ZonFree(gpa, value.*);
                gpa.destroy(value);
            },
            .slice => {
                for (value) |item| zig017ZonFree(gpa, item);
                gpa.free(value);
            },
            else => comptime unreachable,
        },
        .array => for (value) |item| zig017ZonFree(gpa, item),
        .@"struct" => |s| inline for (s.field_names) |n| zig017ZonFree(gpa, @field(value, n)),
        .@"union" => |u| if (u.tag_type != null) switch (value) {
            inline else => |payload| zig017ZonFree(gpa, payload),
        },
        .optional => if (value) |some| zig017ZonFree(gpa, some),
        else => {},
    }
}
ZIGFREE
for my $f (@ARGV) {
  open my $fh, '<', $f or die; my $s = <$fh>; close $fh; my $o = $s;
  $NEED_DUPE = 0;
  $s =~ s{std\.zon\.parse\.(fromSliceAlloc|fromSlice)(\((?:[^()]++|(?2))*\))}{conv($2)}ge;
  $s =~ s{std\.zon\.parse\.free\(}{zig017ZonFree(}g;
  $s .= $DUPE if $NEED_DUPE && $s !~ /fn zig017ZonDupe\(/;
  $s .= $FREE if $s =~ /zig017ZonFree\(/ && $s !~ /fn zig017ZonFree\(/;
  if ($s ne $o) { open my $w, '>', $f or die; print $w $s; close $w; print "$f\n"; }
}
sub split_args { my ($a)=@_; $a =~ s/^\(//; $a =~ s/\)$//; my @p; my $d=0; my $cur='';
  for my $c (split //, $a) { if ($c eq ',' && $d==0) { push @p, $cur; $cur=''; next } $d++ if $c =~ /[\(\[\{]/; $d-- if $c =~ /[\)\]\}]/; $cur.=$c } push @p, $cur if $cur =~ /\S/;
  s/^\s+|\s+$//g for @p; return @p }
sub conv { my ($a)=@_; my @p=split_args($a); return "std.zon.parse.fromSlice$a" unless @p==5;
  my ($t,$al,$src,$diag,$opts)=@p; my $iuf = $opts =~ /ignore_unknown_fields\s*=\s*(\w+)/ ? ", .ignore_unknown_fields = $1" : "";
  if ($diag ne 'null') {
    return "(zig017_zon: { break :zig017_zon std.zon.parse.fromSlice($t, .{ .gpa = $al, .arena = $al, .source = $src, .diagnostics = $diag$iuf }); })";
  }
  $NEED_DUPE = 1;
  return "(zig017_zon: { var zig017_zd: std.zon.parse.Diagnostics = undefined; var zig017_arena: std.heap.ArenaAllocator = .init($al); defer zig017_arena.deinit(); "
       . "const zig017_r = std.zon.parse.fromSlice($t, .{ .gpa = $al, .arena = zig017_arena.allocator(), .source = $src, .diagnostics = &zig017_zd$iuf }); "
       . "break :zig017_zon if (zig017_r) |zig017_v| zig017ZonDupe($t, $al, zig017_v) else |zig017_e| zig017_e; })" }
