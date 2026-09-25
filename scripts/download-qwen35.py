#!/usr/bin/env python3
from model_download import main

if __name__ == "__main__":
    main("qwen3.5-2b", variants={"2b": "qwen3.5-2b", "4b": "qwen3.5-4b"})
