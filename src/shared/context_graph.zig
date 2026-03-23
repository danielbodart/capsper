/// Aho-Corasick context graph for RNNT hot-word biasing and filler suppression.
///
/// Based on sherpa-onnx's ContextGraph (Xiaomi, Apache 2.0) and NVIDIA's
/// TurboBias log-depth scoring (context_graph_universal.py, Apache 2.0).
/// Reference implementations in reference/turbobias/.
///
/// Build a trie from tokenized phrases, with failure links for efficient
/// multi-pattern matching. During RNNT greedy decode, query the graph to
/// boost (positive score) or suppress (negative score) token logits.
const std = @import("std");
const tokenizer = @import("tokenizer.zig");

pub const ContextState = struct {
    token: i32,
    token_score: f32,
    /// Accumulated score from root to this node.
    node_score: f32,
    /// Total score for completed phrase(s) ending at this node.
    output_score: f32,
    is_end: bool,
    level: u32,
    next: std.AutoHashMapUnmanaged(i32, *ContextState),
    fail: *ContextState, // set after build
    output: ?*ContextState, // longest suffix that is a complete phrase
};

pub const ForwardResult = struct {
    score: f32,
    next_state: *const ContextState,
};

pub const ContextGraph = struct {
    allocator: std.mem.Allocator,
    root: *ContextState,
    context_score: f32,
    depth_scaling: f32,

    /// All allocated nodes — for cleanup.
    nodes: std.ArrayListUnmanaged(*ContextState),

    pub fn init(
        allocator: std.mem.Allocator,
        token_map: *const tokenizer.TokenMap,
        phrases: []const []const u8,
        scores: []const f32,
        context_score: f32,
        depth_scaling: f32,
        verbose: bool,
    ) !ContextGraph {
        var self = ContextGraph{
            .allocator = allocator,
            .root = undefined,
            .context_score = context_score,
            .depth_scaling = depth_scaling,
            .nodes = .{},
        };
        errdefer self.deinit();

        // Create root node
        self.root = try self.createNode(-1, 0, 0, 0, false, 0);
        self.root.fail = self.root;

        // Build trie from phrases
        for (phrases, 0..) |phrase, idx| {
            const token_ids = try tokenizer.tokenize(token_map, phrase, allocator);
            defer allocator.free(token_ids);

            if (token_ids.len == 0) continue;

            const phrase_score = if (idx < scores.len and scores[idx] != 0)
                scores[idx]
            else
                context_score;

            if (verbose) {
                std.debug.print("  [bias] \"{s}\" → {d} tokens, score={d:.1}\n", .{ phrase, token_ids.len, phrase_score });
            }

            var node = self.root;
            for (token_ids, 0..) |tok, i| {
                const depth: u32 = @intCast(i);
                // TurboBias log-depth scoring: first token gets base score,
                // subsequent tokens get score * depth_scaling + ln(depth+1)
                const tok_score = if (i > 0)
                    phrase_score * depth_scaling + @log(@as(f32, @floatFromInt(depth + 1)))
                else
                    phrase_score;

                const is_end = (i == token_ids.len - 1);

                if (node.next.get(tok)) |existing| {
                    // Shared prefix — take max score
                    existing.token_score = @max(tok_score, existing.token_score);
                    existing.node_score = node.node_score + existing.token_score;
                    existing.is_end = existing.is_end or is_end;
                    if (is_end) {
                        existing.output_score = existing.node_score;
                    }
                    node = existing;
                } else {
                    const node_score = node.node_score + tok_score;
                    const child = try self.createNode(
                        tok,
                        tok_score,
                        node_score,
                        if (is_end) node_score else 0,
                        is_end,
                        depth + 1,
                    );
                    try node.next.put(allocator, tok, child);
                    node = child;
                }
            }
        }

        // Fill failure and output links via BFS
        try self.fillFailOutput();

        return self;
    }

    pub fn deinit(self: *ContextGraph) void {
        for (self.nodes.items) |node| {
            node.next.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.nodes.deinit(self.allocator);
    }

    /// Advance the trie state by one token. Returns the score delta and new state.
    /// Score delta accounts for failure-link backoff (can be negative when
    /// leaving a partial match).
    pub fn forwardOneStep(self: *const ContextGraph, state: *const ContextState, token_id: i32) ForwardResult {
        _ = self;
        var node: *const ContextState = state;
        var score: f32 = 0;

        if (state.next.get(token_id)) |child| {
            // Direct transition exists
            return .{
                .score = child.token_score + child.output_score,
                .next_state = child,
            };
        }

        // Follow failure links to find a match
        node = state.fail;
        while (node.next.get(token_id) == null) {
            node = node.fail;
            if (node.token == -1) break; // root
        }
        if (node.next.get(token_id)) |child| {
            node = child;
        }
        // Score = new node's accumulated score minus what we had
        // This subtracts the partial credit from the abandoned path
        score = node.node_score - state.node_score;

        return .{
            .score = score + node.output_score,
            .next_state = node,
        };
    }

    /// Cancel accumulated partial-match score. Returns negative score to undo
    /// any partial credit. Call when a hypothesis is finalized (end of utterance).
    pub fn finalize(_: *const ContextGraph, state: *const ContextState) f32 {
        return -state.node_score;
    }

    // ─── Internal ─────────────────────────────────────────────────────────

    fn createNode(
        self: *ContextGraph,
        token: i32,
        token_score: f32,
        node_score: f32,
        output_score: f32,
        is_end: bool,
        level: u32,
    ) !*ContextState {
        const node = try self.allocator.create(ContextState);
        node.* = .{
            .token = token,
            .token_score = token_score,
            .node_score = node_score,
            .output_score = output_score,
            .is_end = is_end,
            .level = level,
            .next = .{},
            .fail = undefined,
            .output = null,
        };
        try self.nodes.append(self.allocator, node);
        return node;
    }

    fn fillFailOutput(self: *ContextGraph) !void {
        var queue: std.ArrayListUnmanaged(*ContextState) = .{};
        defer queue.deinit(self.allocator);

        // Root's direct children fail to root
        var root_iter = self.root.next.iterator();
        while (root_iter.next()) |entry| {
            entry.value_ptr.*.fail = self.root;
            try queue.append(self.allocator, entry.value_ptr.*);
        }

        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const current = queue.items[qi];
            var iter = current.next.iterator();
            while (iter.next()) |entry| {
                const token_id = entry.key_ptr.*;
                const child = entry.value_ptr.*;

                // Find failure link for child
                var fail = current.fail;
                if (fail.next.get(token_id)) |f| {
                    fail = f;
                } else {
                    fail = fail.fail;
                    while (fail.next.get(token_id) == null) {
                        fail = fail.fail;
                        if (fail.token == -1) break; // root
                    }
                    if (fail.next.get(token_id)) |f| {
                        fail = f;
                    }
                }
                child.fail = fail;

                // Fill output link — find nearest ancestor via fail that is_end
                var output: ?*ContextState = child.fail;
                while (output) |o| {
                    if (o.is_end) break;
                    if (o.token == -1) {
                        output = null;
                        break;
                    }
                    output = o.fail;
                }
                child.output = output;
                if (output) |o| {
                    child.output_score += o.output_score;
                }

                try queue.append(self.allocator, child);
            }
        }
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "ContextGraph single word boost" {
    const allocator = std.testing.allocator;

    // Build a minimal token map
    var map: tokenizer.TokenMap = undefined;
    for (&map) |*t| t.* = "";
    map[0] = "\xe2\x96\x81he"; // ▁he
    map[1] = "llo"; // llo
    map[2] = "\xe2\x96\x81cat"; // ▁cat

    // "hello" → tokens [0, 1]
    const phrases = [_][]const u8{"hello"};
    const scores = [_]f32{0}; // use default

    var graph = try ContextGraph.init(allocator, &map, &phrases, &scores, 1.0, 2.0, false);
    defer graph.deinit();

    // From root, token 0 (▁he) should give a boost
    const step1 = graph.forwardOneStep(graph.root, 0);
    try std.testing.expect(step1.score > 0);

    // Continue with token 1 (llo) — should complete the phrase
    const step2 = graph.forwardOneStep(step1.next_state, 1);
    try std.testing.expect(step2.score > 0);
    try std.testing.expect(step2.next_state.is_end);
}

test "ContextGraph negative score suppression" {
    const allocator = std.testing.allocator;

    var map: tokenizer.TokenMap = undefined;
    for (&map) |*t| t.* = "";
    map[0] = "\xe2\x96\x81um"; // ▁um

    const phrases = [_][]const u8{"um"};
    const scores = [_]f32{-2.0}; // suppress

    var graph = try ContextGraph.init(allocator, &map, &phrases, &scores, 1.0, 2.0, false);
    defer graph.deinit();

    // Token 0 (▁um) should give negative score
    const step = graph.forwardOneStep(graph.root, 0);
    try std.testing.expect(step.score < 0);
}

test "ContextGraph unrelated token no effect" {
    const allocator = std.testing.allocator;

    var map: tokenizer.TokenMap = undefined;
    for (&map) |*t| t.* = "";
    map[0] = "\xe2\x96\x81he"; // ▁he
    map[1] = "llo"; // llo
    map[2] = "\xe2\x96\x81cat"; // ▁cat

    const phrases = [_][]const u8{"hello"};
    const scores = [_]f32{0};

    var graph = try ContextGraph.init(allocator, &map, &phrases, &scores, 1.0, 2.0, false);
    defer graph.deinit();

    // Token 2 (▁cat) — not in any phrase, should give zero score
    const step = graph.forwardOneStep(graph.root, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0), step.score, 0.001);
}

test "tokenize roundtrip" {
    const allocator = std.testing.allocator;

    var map: tokenizer.TokenMap = undefined;
    for (&map) |*t| t.* = "";
    map[0] = "\xe2\x96\x81the"; // ▁the
    map[1] = "\xe2\x96\x81cat"; // ▁cat

    const tokens = try tokenizer.tokenize(&map, "the cat", allocator);
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(@as(i32, 0), tokens[0]);
    try std.testing.expectEqual(@as(i32, 1), tokens[1]);
}
