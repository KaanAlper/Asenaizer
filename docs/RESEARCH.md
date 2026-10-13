# Humanizer repository and detector claim review

Reviewed: 2026-10-13. These are repository descriptions and vendor documentation,
not independent benchmark results. No candidate was run on a shared test set here.

| Project | Approach documented by its maintainers | Useful idea for Asenaizer | Evidence limit |
| --- | --- | --- | --- |
| [sgaofen/humanizer-local-model](https://github.com/sgaofen/humanizer-local-model) | Local 12B completion model, exact prompt and sampler, `hz` for structured documents, published evaluation outputs | Keep the exact inference contract and fact checks | Its Originality.ai measurements do not establish a Turnitin result |
| [drmikecrypto/manuscript-humanizer](https://github.com/drmikecrypto/manuscript-humanizer) | Academic document pipeline with ONNX segment scoring and number/citation gates | Compare citation handling and format preservation | Its README describes a detector proxy; that is not Turnitin's private model |
| [opensyndicate/open-humanizer](https://github.com/opensyndicate/open-humanizer) | Writer and critic loop with configurable OpenAI-compatible API plus local heuristics | Keep structured per-attempt feedback | Tests mock the API; a critic's score is not a verified Turnitin score |
| [paniccow/humanizer](https://github.com/paniccow/humanizer) | GRPO experiments and a rule based scrub pipeline | Measure simple baselines before expensive training | Maintainers state their full pipeline was not measured end to end; training requires larger GPUs |
| [AhmadHassan-BTed/Turnitout-Humanizer](https://github.com/AhmadHassan-BTed/Turnitout-Humanizer) | Rule pipeline and document parsing with broad “bypass” marketing | Inspect document parsing separately | A universal pass claim needs independent evidence; the README alone is insufficient |
| [KevinFaurholt/ai-humanize-text](https://github.com/KevinFaurholt/ai-humanize-text) | Multiple LLM and translation steps via external services | Compare style preservation if consent and privacy allow | External services conflict with this project's default local processing goal |

## What the Turnitin documentation actually says

The [Turnitin AI Writing Report guide](https://guides.turnitin.com/hc/en-us/articles/22774058814093-Using-the-AI-Writing-Report)
says its AI percentage differs from similarity score, may be inaccurate, and should not
be the sole basis for action. It describes English language detection of text altered
by paraphrasers or bypass tools. Scores from 1% to 19% are displayed as `*%`, without
a numeric percentage, because Turnitin found more false positives in that range.
Reports also have input requirements, including at least 300 words of qualifying prose.
Thus “below 10% on Turnitin” is usually not directly observable in a current report,
and a result on a short sample is not a comparable measurement.

Turnitin does not publish enough implementation detail to identify its internal
architecture as a specific DeBERTa or RoBERTa model. An open detector can be a useful
proxy, but its score must be labeled by its actual model and version.

## Practical conclusion

Keep the local Humanizer base and the shared installer structure. Prioritize real GPU
speed, citation and fact fidelity, document structure, and a reproducible test corpus.
Do not train a new adapter or advertise a detector pass rate until the baseline has been
measured on the same held out documents and independently checked. A reported detector
score is a dated observation, never a universal guarantee.
