#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "🚀 Activating Qwen Virtual Environment..."
source ../qwen_venv/bin/activate

echo "🚀 Preparing Qwen JSON datasets from latest CSV..."
python3 prepare_qwen_dataset.py

echo "🚀 Launching ms-swift QLoRA Fine-Tuning for Qwen2.5-VL-3B..."
swift sft \
    --model Qwen/Qwen2.5-VL-3B-Instruct \
    --dataset qwen_train.json \
    --val_dataset qwen_val.json \
    --num_train_epochs 3 \
    --max_length 2048 \
    --lora_rank 8 \
    --lora_alpha 32 \
    --gradient_checkpointing true \
    --per_device_train_batch_size 1 \
    --weight_decay 0.1 \
    --learning_rate 1e-4 \
    --gradient_accumulation_steps 16 \
    --output_dir output/qwen2.5-vl-3b-wtt-lora

echo "✅ Training complete! Check the output directory for checkpoints."
