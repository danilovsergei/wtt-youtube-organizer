import sys
import os
sys.path.append('/app/florence_extractor')
import torch
print("PyTorch Version:", torch.__version__)
print("CUDA Available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("Device Name:", torch.cuda.get_device_name(0))

from prod_video_processor import ProdWttVideoProcessor
from PIL import Image

# Initialize the production processor (this loads Qwen via CUDA)
print("Loading ProdWttVideoProcessor in Docker...")
processor = ProdWttVideoProcessor(device="cuda")
processor.initialize_scoreboard_model()

# Pick a known test image
test_image_path = '/workspace/florence_extractor/testdata/clip-10080.0-0.001-2d53558c-d3f3-4fdb-97db-b3c544945822.jpg'
print(f"Running extraction on: {test_image_path}")

img = Image.open(test_image_path)
result = processor.extractor.extract_score(img)

print("================")
print("EXTRACTION RESULT:")
print(f"Success: {result.success}")
print(f"Player 1: '{result.player1}' (Sets: {result.set1}, Points: {result.game1})")
print(f"Player 2: '{result.player2}' (Sets: {result.set2}, Points: {result.game2})")
print(f"Error: {result.error}")
print("================")
