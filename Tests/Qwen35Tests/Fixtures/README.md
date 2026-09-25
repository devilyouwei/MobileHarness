# Tokenization reference fixtures

Purpose: detect differences between Swift and upstream Hugging Face rendering/tokenization before model quality is evaluated.

✅ python-tokenization.json contains ten synthetic message sets, rendered prompts and complete token IDs from transformers 5.17.0 using the pinned Qwen3.5 artifact, add_generation_prompt=true and enable_thinking=false.
❌ These fixtures do not assert semantic answer quality. They preserve a prompt snapshot independently of later Agent documentation edits.
