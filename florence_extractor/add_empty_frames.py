import os
import shutil
import cv2
import pandas as pd

SRC_DIR = "/home/geonix/empty_frames"
BASE_DIR = "/home/geonix/Build/wtt-youtube-organizer/florence_extractor"
TESTDATA_DIR = os.path.join(BASE_DIR, "testdata")
ENHANCED_DIR = os.path.join(BASE_DIR, "testdata_enhanced")
CSV_PATH = os.path.join(BASE_DIR, "test_data_sample.csv")

def enhance_image(img):
    ycrcb = cv2.cvtColor(img, cv2.COLOR_BGR2YCrCb)
    y, cr, cb = cv2.split(ycrcb)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    y_enhanced = clahe.apply(y)
    merged = cv2.merge([y_enhanced, cr, cb])
    enhanced_bgr = cv2.cvtColor(merged, cv2.COLOR_YCrCb2BGR)
    
    h, w = enhanced_bgr.shape[:2]
    x_stretch = 2.0
    target_h = 112
    
    new_w = int(w * x_stretch)
    stretched = cv2.resize(enhanced_bgr, (new_w, h), interpolation=cv2.INTER_LANCZOS4)
    
    scale_y = target_h / h
    scaled_w = int(new_w * scale_y)
    aligned_w = ((scaled_w + 27) // 28) * 28
    
    resized = cv2.resize(stretched, (aligned_w, target_h), interpolation=cv2.INTER_LANCZOS4)
    return resized

def main():
    os.makedirs(TESTDATA_DIR, exist_ok=True)
    os.makedirs(ENHANCED_DIR, exist_ok=True)
    
    empty_files = sorted([f for f in os.listdir(SRC_DIR) if f.lower().endswith(".jpg")])
    print(f"Found {len(empty_files)} empty frames in {SRC_DIR}")
    
    # Backup CSV first
    backup_csv = CSV_PATH + ".backup.before_empty"
    if not os.path.exists(backup_csv):
        shutil.copy2(CSV_PATH, backup_csv)
        print(f"Backed up CSV to {backup_csv}")
        
    df = pd.read_csv(CSV_PATH)
    df.columns = [c.strip() for c in df.columns]
    existing_paths = set(df["image path"].astype(str).str.strip())
    
    new_rows = []
    copied = 0
    enhanced = 0
    
    for fname in empty_files:
        src_path = os.path.join(SRC_DIR, fname)
        raw_dest_path = os.path.join(TESTDATA_DIR, fname)
        enh_dest_path = os.path.join(ENHANCED_DIR, fname)
        
        # 1. Copy raw file
        if not os.path.exists(raw_dest_path):
            shutil.copy2(src_path, raw_dest_path)
            copied += 1
            
        # 2. Enhance image
        if not os.path.exists(enh_dest_path):
            img = cv2.imread(src_path)
            if img is not None and img.size > 0:
                enh_img = enhance_image(img)
                cv2.imwrite(enh_dest_path, enh_img, [cv2.IMWRITE_JPEG_QUALITY, 95])
                enhanced += 1
            else:
                print(f"Warning: could not read {src_path}")
                continue
                
        # 3. Record CSV row
        rel_path = f"testdata/{fname}"
        if rel_path not in existing_paths:
            new_rows.append({
                "image path": rel_path,
                "row 1 expected player": "EMPTY",
                "row 2 expected player 2": "EMPTY",
                "row 1 set score": -1,
                "row 2 set score": -1,
                "row 1 game score": -1,
                "row 2 game score": -1
            })
            existing_paths.add(rel_path)
            
    print(f"Copied {copied} raw images to testdata/")
    print(f"Generated {enhanced} enhanced images in testdata_enhanced/")
    
    if new_rows:
        new_df = pd.DataFrame(new_rows)
        df_updated = pd.concat([df, new_df], ignore_index=True)
        df_updated.to_csv(CSV_PATH, index=False)
        print(f"Appended {len(new_rows)} rows to {CSV_PATH}. Total rows now: {len(df_updated)}")
    else:
        print("No new rows needed in CSV.")

if __name__ == "__main__":
    main()
