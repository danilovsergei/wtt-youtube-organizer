#!/usr/bin/env python3
import os
import subprocess
import sys

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sh_script = os.path.join(script_dir, "train_mineru.sh")
    print("🚀 Launching MinerU 2.5-Pro training...")
    res = subprocess.run(["bash", sh_script], cwd=script_dir)
    sys.exit(res.returncode)

if __name__ == "__main__":
    main()
