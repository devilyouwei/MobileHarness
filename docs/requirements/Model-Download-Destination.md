# Shared model download destination

Root Models is the shared artifact location for Tests and experiments. Completed: scripts/models/model_download.py writes every profile to Models/<model>, and Nemotron, Silero and MossTTSNano Swift tests read from there. MobileHarness/Resources/Models has been removed and must not be recreated. New model artifacts for Tests or experiments go only under root Models and stay Git-ignored (/Models/*/). Production App-managed storage and the catalog (MobileHarness/ModelKit/Support/Config/model-catalog.json) are unchanged.
