import { describe, expect, it } from "vitest";
import { gpuSwitches } from "../src/gpu.js";

describe("WebGPU backend switches", () => {
  it("enables Chromium's Vulkan backend on Linux, where Dawn only reaches a GPU adapter through it", () => {
    expect(gpuSwitches("linux", "")).toEqual([{ name: "enable-features", value: "Vulkan" }]);
  });

  it("keeps the features an embedder already set instead of replacing them", () => {
    expect(gpuSwitches("linux", "Metal, Vulkan")).toEqual([{ name: "enable-features", value: "Metal,Vulkan" }]);
    expect(gpuSwitches("linux", "SomeFeature")).toEqual([{ name: "enable-features", value: "SomeFeature,Vulkan" }]);
  });

  it.each(["darwin", "win32"] as const)("adds nothing on %s, where WebGPU does not need the opt-in", (platform) => {
    expect(gpuSwitches(platform, "")).toEqual([]);
  });
});
