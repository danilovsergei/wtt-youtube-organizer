# Match Start Finder - Design Document

Multi-phase strategy for efficiently finding match start timestamps in table tennis videos using Florence-2 OCR.

## Overview

For a 5-hour video (~18,000 seconds), the goal is to find all match starts in under 30 minutes using intelligent sampling instead of scanning every frame.\
Sometimes scoreboard starts with 0:0 , sometimes they display it only when the score is 0:1 after first point.



## Phase 1: Coarse Scan (Initial Sampling)

**Interval:** Sample every 3 minutes (180 seconds)
**Images extracted:** 18,000 / 180 = ~100 images
**OCR time:** 100 × 2s = ~200 seconds (3.3 min)
**Purpose:** Identify regions where score overlays are visible and get a rough map of the video

**Outcomes per sample:**

1. ✅ **Valid score detected** → Mark region as "active match"
2. ❌ **No score (error/empty)** → Mark as "no match" (break, intro, replay, etc.)
3. 🎯 **Score is 0:0, 0:0** → Potential match start found!



## Phase 2: Boundary Detection (Find Match Transitions)

For each transition from "no match" → "active match":
- This is likely a match start region
- Use **binary search** to narrow down the exact 0:0 timestamp

**Binary Search Logic:**

1. Take the last "no match" timestamp (T1) and first "active match" timestamp (T2)
2. Sample the midpoint (T1 + T2) / 2
3. If score is 0:0 → found it (or slight refinement needed)
4. If score is non-zero → the 0:0 must be between T1 and midpoint
5. If no score → expand toward T2
6. Repeat until precision is ~10-15 seconds

**Cost per match start:** ~5-8 binary search steps × 2 seconds = ~10-16 seconds


## Phase 3: In-Match Start Detection (New Games within a Match)

When we find a match in progress with sets > 0 (e.g., sets 2:1), we know previous games started at 0:0.

**Backward Search Strategy:**

From a non-zero score, estimate backward using game duration:
- If current game score is N points, go back approximately `N × 16 seconds`
- If current set score is M, we need to find M previous game starts

**Exponential Backoff Search:**

1. From current position, jump back by estimated game duration (~3 min)
2. Check the score - if same game but lower points, continue backward
3. If different game (or 0:0 game), binary search to refine
4. Track game transitions (when game score resets to 0)


## Phase 4: Handle No-Score Frames (Retry Strategy)

Since random frames may not show the score (replays, crowd shots, etc.):
- If OCR fails, sample **±5 seconds** from the same position (up to 3 retries)
- Most valid gameplay frames show the score overlay


## Algorithm Summary

```
1. COARSE SCAN (every 180s → ~100 samples)
   For each sample:
   - Extract frame → OCR
   - Classify: NO_SCORE / VALID_SCORE / MATCH_START (0:0, 0:0)
   
2. FIND TRANSITIONS
   For each NO_SCORE → VALID_SCORE transition:
   - Binary search to find exact match start (0:0, 0:0)
   - ~5-8 OCR calls per match
   
3. FIND IN-MATCH GAME STARTS
   For each active match region:
   - If game score > 0: backward search to find game start
   - If set score > 0: estimate and search for previous games
   
4. RETRY ON EMPTY FRAMES
   - Sample ±5s offsets if OCR fails (max 3 retries)
```

## Estimated Total Cost
On lenovo x1 carbon x12 Intel GPU scanning of the 5 hours video takes about 15-20 minutes
Running on CPU takes around 80 minutes.

## Implementation Files

| File | Purpose |
|------|---------|
| `match_start_finder.py` | Main algorithm implementation |
| `score_extractor.py` | Score extraction and OCR utilities |
| `train_florence2.py` | Model training script |
| `convert_to_openvino.py` | OpenVINO conversion for Intel GPU |
| `backends/` | Inference backend implementations |
