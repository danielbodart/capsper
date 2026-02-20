import { describe, test, expect } from "bun:test";
import { wordEditDistance, formatAlignment, normalize } from "./helpers";

describe("wordEditDistance", () => {
    test("both empty", () => {
        const r = wordEditDistance([], []);
        expect(r.matches).toBe(0);
        expect(r.substitutions).toBe(0);
        expect(r.insertions).toBe(0);
        expect(r.deletions).toBe(0);
        expect(r.ops).toEqual([]);
    });

    test("perfect match", () => {
        const r = wordEditDistance(["a", "b", "c"], ["a", "b", "c"]);
        expect(r.matches).toBe(3);
        expect(r.substitutions).toBe(0);
        expect(r.insertions).toBe(0);
        expect(r.deletions).toBe(0);
        expect(r.ops).toEqual(["match", "match", "match"]);
    });

    test("single substitution", () => {
        const r = wordEditDistance(["a"], ["b"]);
        expect(r.matches).toBe(0);
        expect(r.substitutions).toBe(1);
        expect(r.insertions).toBe(0);
        expect(r.deletions).toBe(0);
        expect(r.refAlign).toEqual(["a"]);
        expect(r.streamAlign).toEqual(["b"]);
    });

    test("single insertion (extra stream word)", () => {
        const r = wordEditDistance(["a"], ["a", "b"]);
        expect(r.matches).toBe(1);
        expect(r.insertions).toBe(1);
        expect(r.deletions).toBe(0);
        expect(r.substitutions).toBe(0);
    });

    test("single deletion (missing ref word)", () => {
        const r = wordEditDistance(["a", "b"], ["a"]);
        expect(r.matches).toBe(1);
        expect(r.deletions).toBe(1);
        expect(r.insertions).toBe(0);
        expect(r.substitutions).toBe(0);
    });

    test("substitution in middle", () => {
        const r = wordEditDistance(["a", "b", "c"], ["a", "x", "c"]);
        expect(r.matches).toBe(2);
        expect(r.substitutions).toBe(1);
        expect(r.refAlign).toEqual(["a", "b", "c"]);
        expect(r.streamAlign).toEqual(["a", "x", "c"]);
    });

    test("empty ref, all insertions", () => {
        const r = wordEditDistance([], ["a", "b"]);
        expect(r.insertions).toBe(2);
        expect(r.matches).toBe(0);
        expect(r.deletions).toBe(0);
    });

    test("empty stream, all deletions", () => {
        const r = wordEditDistance(["a", "b"], []);
        expect(r.deletions).toBe(2);
        expect(r.matches).toBe(0);
        expect(r.insertions).toBe(0);
    });

    test("mixed operations", () => {
        // ref:    "the cat sat on the mat"
        // stream: "the dog sat on a mat here"
        const ref = ["the", "cat", "sat", "on", "the", "mat"];
        const stream = ["the", "dog", "sat", "on", "a", "mat", "here"];
        const r = wordEditDistance(ref, stream);
        expect(r.matches).toBe(4); // the, sat, on, mat
        expect(r.substitutions).toBe(2); // cat->dog, the->a
        expect(r.insertions).toBe(1); // here
        expect(r.deletions).toBe(0);
    });

    test("op counts sum to alignment length", () => {
        const ref = ["a", "b", "c", "d"];
        const stream = ["a", "x", "y", "d", "e"];
        const r = wordEditDistance(ref, stream);
        expect(r.matches + r.substitutions + r.insertions + r.deletions).toBe(r.ops.length);
    });
});

describe("formatAlignment", () => {
    test("all matches", () => {
        const r = wordEditDistance(["a", "b"], ["a", "b"]);
        expect(formatAlignment(r)).toBe("a b");
    });

    test("substitution renders correctly", () => {
        const r = wordEditDistance(["world"], ["car"]);
        expect(formatAlignment(r)).toBe("[~world\u2192car~]");
    });

    test("insertion renders correctly", () => {
        const r = wordEditDistance(["a"], ["a", "extra"]);
        expect(formatAlignment(r)).toContain("{+extra+}");
    });

    test("deletion renders correctly", () => {
        const r = wordEditDistance(["a", "b"], ["a"]);
        expect(formatAlignment(r)).toContain("[-b-]");
    });

    test("mixed operations", () => {
        const r = wordEditDistance(["hello", "world"], ["hello", "car"]);
        expect(formatAlignment(r)).toBe("hello [~world\u2192car~]");
    });
});

describe("normalize", () => {
    test("lowercases and strips punctuation", () => {
        expect(normalize("Hello, World!")).toBe("hello world");
    });

    test("preserves apostrophes", () => {
        expect(normalize("it's we're")).toBe("it's we're");
    });

    test("collapses whitespace", () => {
        expect(normalize("  hello   world  ")).toBe("hello world");
    });
});
