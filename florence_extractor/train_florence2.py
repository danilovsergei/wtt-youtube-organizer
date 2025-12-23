import os
import pandas as pd
from PIL import Image
import torch
from torch.utils.data import Dataset, DataLoader
from transformers import AutoProcessor, AutoModelForCausalLM, get_scheduler
from torch.optim import AdamW
from tqdm import tqdm


class TableTennisDataset(Dataset):
    def __init__(self, csv_file, processor, base_dir):
        self.data = pd.read_csv(csv_file)
        self.processor = processor
        self.base_dir = base_dir

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        row = self.data.iloc[idx]
        image_path = row['image path']
        # Resolve relative path to base_dir
        if not os.path.isabs(image_path):
            image_path = os.path.join(self.base_dir, image_path)
        try:
            image = Image.open(image_path).convert("RGB")
        except Exception as e:
            print(f"Error loading image {image_path}: {e}")
            # Return a dummy item or handle error
            return None

        # Construct the target text
        target_text = (
            f"row 1: {row['row 1 expected player']}, {row['row 1 set score']}, {row['row 1 game score']} "
            f"row 2: {row['row 2 expected player 2']}, {row['row 2 set score']}, {row['row 2 game score']}"
        )

        prompt = "<OCR>"

        # Florence-2 uses specific formatting
        inputs = self.processor(text=prompt, images=image, return_tensors="pt")

        # Tokenize labels
        with self.processor.tokenizer.as_target_tokenizer():
            labels = self.processor.tokenizer(
                text=target_text,
                return_tensors="pt",
                padding="max_length",
                max_length=128,
                truncation=True
            ).input_ids

        labels = labels.squeeze()
        # Replace padding token id with -100 to ignore loss on padding
        labels[labels == self.processor.tokenizer.pad_token_id] = -100

        return {
            "input_ids": inputs["input_ids"].squeeze(),
            "pixel_values": inputs["pixel_values"].squeeze(),
            "labels": labels
        }


def collate_fn(batch):
    batch = [item for item in batch if item is not None]
    return {
        "input_ids": torch.stack([item["input_ids"] for item in batch]),
        "pixel_values": torch.stack([item["pixel_values"] for item in batch]),
        "labels": torch.stack([item["labels"] for item in batch])
    }


def train():
    device = torch.device("cpu")
    model_id = "microsoft/Florence-2-base"

    print(f"Using device: {device}")
    print(f"Loading model {model_id}...")
    processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_id, trust_remote_code=True, attn_implementation="eager").to(device)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(script_dir, "test_data_sample.csv")
    dataset = TableTennisDataset(csv_path, processor, script_dir)
    # Use a subset of 5 images for quick demo
    # dataset.data = dataset.data.head(5)
    train_loader = DataLoader(dataset, batch_size=1,
                              shuffle=True, collate_fn=collate_fn)

    optimizer = AdamW(model.parameters(), lr=1e-5)

    num_epochs = 5
    num_training_steps = num_epochs * len(train_loader)
    lr_scheduler = get_scheduler(
        name="linear", optimizer=optimizer, num_warmup_steps=0, num_training_steps=num_training_steps
    )

    model.train()
    # scaler is only for CUDA
    for epoch in range(num_epochs):
        loop = tqdm(train_loader, leave=True)
        for batch in loop:
            optimizer.zero_grad()

            input_ids = batch["input_ids"].to(device)
            pixel_values = batch["pixel_values"].to(device)
            labels = batch["labels"].to(device)

            outputs = model(input_ids=input_ids,
                            pixel_values=pixel_values, labels=labels)
            loss = outputs.loss

            loss.backward()
            optimizer.step()
            lr_scheduler.step()

            loop.set_description(f"Epoch {epoch}")
            loop.set_postfix(loss=loss.item())

    print("Training complete. Saving model...")
    output_dir = os.path.join(script_dir, "florence2-tt-finetuned")
    model.save_pretrained(output_dir)
    processor.save_pretrained(output_dir)
    print(f"Model saved to {output_dir}")


if __name__ == "__main__":
    train()
