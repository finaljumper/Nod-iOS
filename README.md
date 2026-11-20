# Nod-iOS

A native iPhone and iPad voice and chat client for a self-hosted
[Nod](https://github.com/n8n-io/nod) agent, together with the speech recognition benchmark
and the documents that led to it.

Speech is recognised and replies are spoken on the device. Nod, reached over HTTPS, stays
the only thing that reasons and acts.

| Where | What |
| --- | --- |
| [NodCompanion/](NodCompanion/README.md) | The app: type or speak a request, read and hear the reply, see what Nod is doing, approve or refuse sensitive actions, and talk hands-free. Its README says how to build it, how it talks to Nod, and what is not done yet |
| [VoiceASRBenchmark/](VoiceASRBenchmark/README.md) | A SwiftUI app that runs the same prerecorded speech through several on-device recognisers and compares accuracy, latency and resource use |
| [Nod_Voice_Companion_Project_Brief.md](Nod_Voice_Companion_Project_Brief.md) | The product brief and roadmap |
| [Nod_Voice_Companion_Implementation.md](Nod_Voice_Companion_Implementation.md) | The implementation specification, written from Nod's server source |

To build the app, start with
[Getting started](NodCompanion/README.md#getting-started) in its README.

Voice models and recorded speech datasets are not in the repository. The app's README names
the scripts that fetch the models.

Licensed under the Apache License 2.0; see [LICENSE](LICENSE).
