import json
import pandas as pd
from sklearn.model_selection import GroupShuffleSplit
import os

# 1. Load dataset
csv_path = '/home/geonix/Build/wtt-youtube-organizer/florence_extractor/test_data_sample.csv'
df = pd.read_csv(csv_path)
df.columns = [c.strip() for c in df.columns]

# 2. Standardize all names to uppercase
df['row 1 expected player'] = df['row 1 expected player'].str.strip().str.upper()
df['row 2 expected player 2'] = (
    df['row 2 expected player 2'].str.strip().str.upper()
)

# 3. Create matchup grouping key to prevent data leakage
df['matchup'] = (
    df['row 1 expected player'] + ' vs ' + df['row 2 expected player 2']
)

# 4. Grouped Train/Val Split (85% Train, 15% Val)
gss = GroupShuffleSplit(n_splits=1, test_size=0.15, random_state=42)
train_idx, val_idx = next(gss.split(df, groups=df['matchup']))

train_df = df.iloc[train_idx]
val_df = df.iloc[val_idx]

print(f'Train set: {len(train_df)} frames across {train_df["matchup"].nunique()} matches')
print(f'Val set:   {len(val_df)} frames across {val_df["matchup"].nunique()} matches')

# 5. Converter to Qwen ChatML conversational format
def convert_to_qwen_sft(dataframe, output_json_path):
  dataset = []
  prompt_text = (
      'Examine this World Table Tennis (WTT) broadcast scoreboard image. '
      'Extract the player names and scores into a valid JSON object matching this schema:\\n'
      '{\\n'
      '  "row_1_name": "string",\\n'
      '  "row_1_sets": integer,\\n'
      '  "row_1_points": integer,\\n'
      '  "row_2_name": "string",\\n'
      '  "row_2_sets": integer,\\n'
      '  "row_2_points": integer\\n'
      '}'
  )

  for _, row in dataframe.iterrows():
    target_json = {
        'row_1_name': row['row 1 expected player'],
        'row_1_sets': int(row['row 1 set score']),
        'row_1_points': int(row['row 1 game score']),
        'row_2_name': row['row 2 expected player 2'],
        'row_2_sets': int(row['row 2 set score']),
        'row_2_points': int(row['row 2 game score']),
    }

    # Ensure absolute path for images so ms-swift can find them
    img_rel_path = row['image path']
    # The image path in the CSV usually looks like 'testdata/clip-3000...jpg'
    img_abs_path = os.path.abspath(os.path.join('/home/geonix/Build/wtt-youtube-organizer/florence_extractor', img_rel_path))

    conversation = {
        'messages': [
            {
                'role': 'user',
                'content': [
                    {'type': 'image', 'image': img_abs_path},
                    {'type': 'text', 'text': prompt_text},
                ],
            },
            {'role': 'assistant', 'content': json.dumps(target_json)},
        ]
    }
    dataset.append(conversation)

  with open(output_json_path, 'w', encoding='utf-8') as f:
    json.dump(dataset, f, indent=2, ensure_ascii=False)

  print(f'Saved {len(dataset)} samples to {output_json_path}')

convert_to_qwen_sft(train_df, '/home/geonix/Build/wtt-youtube-organizer/florence_extractor/qwen_train.json')
convert_to_qwen_sft(val_df, '/home/geonix/Build/wtt-youtube-organizer/florence_extractor/qwen_val.json')
