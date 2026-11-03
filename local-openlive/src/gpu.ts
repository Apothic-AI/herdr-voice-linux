// Chromium's Vulkan backend is opt-in on Linux, and Dawn only gets a WebGPU adapter through it. Without this
// switch the renderer sees `navigator.gpu` but `requestAdapter()` resolves to null, so startup stops with
// "WebGPU adapter unavailable". macOS reaches WebGPU through Metal and needs nothing here.
//
// This selects a GPU backend; it is not a quality or CPU fallback. Local mode still refuses to start without a
// real WebGPU adapter, and there is no wasm/CPU inference path.
export type Switch = { name: string; value?: string };

export function gpuSwitches(platform: NodeJS.Platform, existingEnableFeatures: string): Switch[] {
  if (platform !== "linux") return [];
  const features = existingEnableFeatures
    .split(",")
    .map((feature) => feature.trim())
    .filter(Boolean);
  if (!features.includes("Vulkan")) features.push("Vulkan");
  return [{ name: "enable-features", value: features.join(",") }];
}
