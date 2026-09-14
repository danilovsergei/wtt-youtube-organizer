#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "🚀 Activating Qwen Virtual Environment..."
source ../qwen_venv/bin/activate

echo "🚀 Launching ms-swift QLoRA Fine-Tuning for Qwen2.5-VL-3B..."
swift sft \\
    --model_type qwen2_5-vl-3b-instruct \\
    --model_id_or_path Qwen/Qwen2.5-VL-3B-Instruct \\
    --sft_type lora \\
    --tuner_backend peft \\
    --dtype bfloat16 \\
    --dataset qwen_train.json \\
    --val_dataset qwen_val.json \\
    --train_dataset_sample -1 \\
    --num_train_epochs 3 \\
    --max_length 2048 \\
    --check_dataset_strategy warning \\
    --lora_rank 8 \\
    --lora_alpha 32 \\
    --lora_dropout_p 0.05 \\
    --lora_target_modules ALL \\
    --gradient_checkpointing true \\
    --batch_size 1 \\
    --weight_decay 0.1 \\
    --learning_rate 1e-4 \\
    --gradient_accumulation_steps 16 \\
    --output_dir output/qwen2.5-vl-3b-wtt-lora

echo "✅ Training complete! Check the output directory for checkpoints."
