# Shared model download destination

Root Models is the agreed shared artifact location. scripts/models/model_download.py currently writes only Gemma macOS there; other profiles still write MobileHarness/Resources/Models. Migrate development destinations and their engineering consumers together, preserving production App-managed storage, existing artifact reuse and verification. This remains pending; the root README documents the current behavior.
