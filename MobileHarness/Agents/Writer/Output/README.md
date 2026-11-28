# Writer output

Presentation of Writer work.

| File | Responsibility |
| --- | --- |
| [WriterIslandPresentation.swift](WriterIslandPresentation.swift) | Island presentation of Writer activity. |
| [WriterPreview.swift](WriterPreview.swift) | Artifact preview projection. |

[WriterToolDispatch.swift](WriterToolDispatch.swift) sends workspace calls through the bound consumer. [WriterTaskReports.swift](WriterTaskReports.swift) delivers progress, milestones and terminal events. [WriterRecordQueries.swift](WriterRecordQueries.swift) projects persisted records for UI queries. [WriterRequestPresentation.swift](WriterRequestPresentation.swift) derives request titles and presentation state from recorded tool activity.
