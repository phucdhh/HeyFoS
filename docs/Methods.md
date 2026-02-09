# Processing Methods in HeyFoS

Based on analysis of industry standards (Zerene Stacker, Helicon Focus) and our own optimization progress, HeyFoS offers two distinct focus stacking strategies tailored for different subjects.

## 1. DepthMap (formerly "Max Fusion")

**Algorithm:** Pixel-level Depth Map / Weighted Max Selection  
**Best for:** Maximum sharpness, scientific detail, flat subjects.

*   **How it works:** 
    *   Calculates a focus score for every pixel in every layer using Laplacian/Tenengrad filters.
    *   Selects the pixel with the highest score (or weighted average of top scores) for the final image.
*   **Pros:**
    *   Extremely sharp results.
    *   Preserves high-frequency details perfectly.
*   **Cons:**
    *   Can introduce noise if the source images are noisy.
    *   May create "halos" or artifacts at steep depth discontinuities (edges of objects).
*   **Implementation:** `FocusMeasure.swift` (Laplacian/Tenengrad kernels).

## 2. PyBlend (formerly "Pyramid Blending")

**Algorithm:** Laplacian Pyramid Blending with Robust Weight Normalization  
**Best for:** Complex geometries, overlapping structures, insect photography, artistic macro.

*   **How it works:**
    *   Decomposes images into different frequency bands (Pyramid levels).
    *   Blends these frequencies separately based on contrast analysis.
    *   Uses "Robust Normalization" (Outlier Rejection + Gamma Curve) to filter noise and preserve natural transitions.
*   **Pros:**
    *   Very smooth transitions between focus layers.
    *   Eliminates halo artifacts common in DMap.
    *   Handles transparency/overlapping hairs (e.g., on insects) much better.
*   **Cons:**
    *   Slightly softer than DepthMap (rated ~8.5/10 sharpness compared to Zerene PMax).
*   **Implementation:** `PyramidBlending.swift` (GPU-accelerated via Metal Compute Shaders).

---

## Documentation Structure

All project documentation has been centralized in the `docs/` directory:

*   `docs/Methods.md`: This file (Algorithm explanations).
*   `docs/PROGRESS.md`: Development logs and milestones.
*   `docs/README.md`: General usage instructions (moved from root).
