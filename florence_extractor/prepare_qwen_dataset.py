import json
import pandas as pd
from sklearn.model_selection import GroupShuffleSplit
import os

# 1. Load dataset
csv_path = "/home/geonix/Build/wtt-youtube-organizer/florence_extractor/test_data_sample.csv"
df = pd.read_csv(csv_path)
df.columns = [c.strip() for c in df.columns]

# 2. Standardize all names to uppercase
df["row 1 expected player"] = df["row 1 expected player"].fillna("").astype(str).str.strip().str.upper()
df["row 2 expected player 2"] = df["row 2 expected player 2"].fillna("").astype(str).str.strip().str.upper()

# 3. Create matchup grouping key to prevent data leakage
is_empty = (df["row 1 expected player"].isin(["", "EMPTY", "NONE", "NAN"])) | (df["row 1 set score"] == -1)

# For positive frames, group by matchup so same match never leaks between train and val
df["matchup"] = df["row 1 expected player"] + " vs " + df["row 2 expected player 2"]

# For empty frames, assign unique groups so GroupShuffleSplit distributes them proportionally (85% / 15%)
empty_indices = df[is_empty].index
for i, idx in enumerate(empty_indices):
    df.loc[idx, "matchup"] = f"EMPTY_FRAME_{i}"

# 4. Grouped Train/Val Split (85% Train, 15% Val)
gss = GroupShuffleSplit(n_splits=1, test_size=0.15, random_state=42)
train_idx, val_idx = next(gss.split(df, groups=df["matchup"]))

train_df = df.iloc[train_idx]
val_df = df.iloc[val_idx]

train_empty_cnt = (train_df["row 1 expected player"] == "EMPTY").sum()
val_empty_cnt = (val_df["row 1 expected player"] == "EMPTY").sum()

print(f"Train set: {len(train_df)} frames ({train_empty_cnt} empty, {len(train_df)-train_empty_cnt} positive)")
print(f"Val set:   {len(val_df)} frames ({val_empty_cnt} empty, {len(val_df)-val_empty_cnt} positive)")
print(f"Empty ratio - Train: {train_empty_cnt/len(train_df)*100:.2f}%, Val: {val_empty_cnt/len(val_df)*100:.2f}%")

PROMPT_TEXT = """Examine this World Table Tennis (WTT) broadcast scoreboard image.
WARNING: Do not autocorrect or normalize spelling. Foreign names frequently contain unusual double consonants.
You MUST transcribe the literal pixels exactly as printed, character-by-character.
To prevent spelling errors, transcribe the player names by inserting a pipe '|' between EVERY SINGLE CHARACTER (e.g., M|O|H|A|M|M|E|D). Do not group letters into words.
Output a valid JSON object matching this schema:
{
  "row_1_name": "string (pipe-delimited)",
  "row_1_sets": integer,
  "row_1_points": integer,
  "row_2_name": "string (pipe-delimited)",
  "row_2_sets": integer,
  "row_2_points": integer
}
If NO scoreboard is visible in the image, output an empty JSON object: {}"""

def convert_to_qwen_sft(dataframe, output_json_path):
    dataset = []
    
    for _, row in dataframe.iterrows():
        p1 = row["row 1 expected player"]
        empty_sample = (p1 in ["", "EMPTY", "NONE", "NAN"]) or (int(row["row 1 set score"]) == -1)
        
        if empty_sample:
            assistant_text = "{}"
        else:
            target_json = {
                "row_1_name": "|".join(list(p1)),
                "row_1_sets": int(row["row 1 set score"]),
                "row_1_points": int(row["row 1 game score"]),
                "row_2_name": "|".join(list(row["row 2 expected player 2"])),
                "row_2_sets": int(row["row 2 set score"]),
                "row_2_points": int(row["row 2 game score"]),
            }
            assistant_text = json.dumps(target_json)

        img_rel_path = row["image path"].replace("testdata/", "testdata_enhanced/")
        img_abs_path = os.path.abspath(os.path.join("/home/geonix/Build/wtt-youtube-organizer/florence_extractor", img_rel_path))
        
        if not os.path.exists(img_abs_path):
            raise FileNotFoundError(f"Image not found: {img_abs_path}")

        conversation = {
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "image", "image": img_abs_path},
                        {"type": "text", "text": PROMPT_TEXT}
                    ]
                },
                {
                    "role": "assistant",
                    "content": [
                        {"type": "text", "text": assistant_text}
                    ]
                }
            ]
        }
        dataset.append(conversation)

    with open(output_json_path, "w", encoding="utf-8") as f:
        json.dump(dataset, f, indent=2, ensure_ascii=False)

    print(f"Saved {len(dataset)} samples to {output_json_path}")

convert_to_qwen_sft(train_df, "/home/geonix/Build/wtt-youtube-organizer/florence_extractor/qwen_train.json")
convert_to_qwen_sft(val_df, "/home/geonix/Build/wtt-youtube-organizer/florence_extractor/qwen_val.json")
