#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "🚀 Activating Virtual Environment..."
source ../qwen_venv/bin/activate

echo "🚀 Preparing JSON datasets from latest CSV..."
python3 prepare_qwen_dataset.py

echo "🚀 Launching ms-swift QLoRA Fine-Tuning for MinerU2.5-Pro-2605-1.2B..."
swift sft \
    --model opendatalab/MinerU2.5-Pro-2605-1.2B \
    --model_type qwen2_vl \
    --template qwen2_vl \
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
    --output_dir output/mineru2.5-pro-1.2b-wtt-lora

echo "✅ Training complete! Check output/mineru2.5-pro-1.2b-wtt-lora for checkpoints."
