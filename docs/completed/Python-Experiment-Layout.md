# Python experiment layout

Use lowercase snake_case task and data directories under experiments. Add package markers to Python code directories only, enabling recursive unittest discovery while retaining direct script entry points. Keep datasets/results as task-owned data, not Python packages. Update active path references and naming rules; preserve frozen data provenance. No new directories or engineering dependencies.

Completed: lowercase task/data directories and Python package markers; 21 tests discovered in one command, four main CLI help checks and Xcode plist validation passed. Frozen provenance unchanged.
