

**Autonym**

*A Self-Sovereign Identity System*

*for the Mesh Republic*

Version 1.0, February 2026

Primary Author: Lee Hansen

License: GNU Affero General Public License v3.0 (AGPL-3.0)

Repository: github.com/MeshRepublic/kudzu (docs/whitepaper)

Parent Project: The Mesh Republic, github.com/meshrepublic/mesh-republic-whitepaper

*"Identity is not a document. It is a pattern."*

| LICENSE NOTICE Copyright (C) 2026 Lee Hansen This document and all associated reference implementations are free software: you may redistribute and/or modify them under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. You should have received a copy of the GNU Affero General Public License along with this document. If not, see https://www.gnu.org/licenses/ |
| :---- |

# **Abstract**

Autonym is a self-sovereign identity system in which every citizen is their own Certificate Authority. Identity is not granted by a central institution and cannot be revoked by one. Instead, identity emerges from the accumulated weight of a continuously growing web of mutual validation, behavioral continuity, relationship attestations, economic presence, and community participation, anchored cryptographically to the Bitcoin blockchain and verified through zero-knowledge proofs.

This paper specifies the Autonym architecture: its philosophical foundations, cryptographic primitives, trust propagation model, Sybil resistance mechanism, integration with the Kudzu biomimetic memory system, and its bootstrapping strategy from within existing legacy identity infrastructure. Autonym is not a replacement imposed from outside; it is a parallel system that demonstrates superior properties and displaces legacy identity by competitive merit.

# **1\. The Identity Inversion Problem**

## **1.1 How Identity Actually Works**

For two hundred thousand years, humans have known each other without government documents. Identity is established through the accumulated weight of shared context: you are who your community knows you to be. Your neighbors have seen you. Your family is traceable. Your employer knows your face and your work. Your bank has your transaction history. Your landlord has your rent receipts. The aggregate of these relationships constitutes identity far more robustly than any single document.

A person who is well-known in their town is known regardless of whether their wallet was stolen, their ID expired, or their citizenship was questioned by a bureaucracy. The community's knowledge does not disappear.

## **1.2 The Central Authority Inversion**

Modern state identity systems inverted this natural order. They declared: "You are not who your community knows you to be. You are who we, the central authority, declare you to be. Your identity flows downward from our stamp, not upward from your relationships."

This inversion was accepted because it was convenient and because it scaled trust to strangers in contexts where organic trust networks did not exist. But the inversion created a catastrophic structural vulnerability: a single point of failure and a single point of control. Lose your government ID and you become a non-person, not because your community stopped knowing you, but because the central authority stopped acknowledging you.

This is not a hypothetical risk. It is an operational risk exercised routinely: against dissidents, against refugees, against minorities, against anyone who inconveniences a centralized power structure.

## **1.3 The Autonym Re-Inversion**

Autonym re-inverts identity back to its natural state. It returns identity authority to the distributed web of relationships that has always constituted identity in practice, while using the legacy system's own records as inputs rather than authorities.

The government ID does not disappear; it becomes one data point among thousands. The utility bill does not disappear; it contributes a thread of evidence. The employment record, the marriage certificate, the family relationship, the continuous behavioral signature of a mobile device: all of these become threads in a rope that no single institution can cut.

# **2\. Core Principles**

**2.1 Every Citizen Is Their Own Certificate Authority**

There is no root CA. Every Autonym participant generates their own cryptographic keypair and issues their own identity attestations. Their identity is the accumulation of their attestations and the attestations of others who know them.

**2.2 Trust Flows Upward, Not Downward**

Identity is established by the weight of community validation, not by the grant of a central institution. A citizen with deep community roots has a stronger identity than one with a freshly issued government document and no social graph.

**2.3 No Single Thread Is Sufficient; No Single Cut Is Fatal**

Each validation thread is independently insufficient to establish identity. Together they form a rope. Destroying any single thread does not destroy the identity. This is the fractal property: the pattern is self-similar at every scale, and resilience is distributed throughout the structure.

**2.4 Zero-Knowledge by Default**

A citizen can prove the existence and strength of their identity without revealing its contents. The default state is: "I am a validated human with a continuous identity record." Additional disclosure is the citizen's choice.

**2.5 Legacy Systems Are Inputs, Not Authorities**

Existing record infrastructure, government databases, utility records, employment verification, financial history, is treated as evidence that can strengthen an Autonym but cannot constitute or negate one. The legacy system contributes to the rope; it does not hold the scissors.

**2.6 The System Emerges from Within**

Autonym does not require the legacy system to be dismantled before it can function. It is designed to operate in parallel and to displace legacy identity by competitive merit.

# **3\. Architecture Overview**

An Autonym consists of four layers:

| ┌──────────────────────────────────────────────────┐ │  LAYER 4: ZERO-KNOWLEDGE PROOF PRESENTATION             │ │  Prove identity strength without revealing contents      │ ├──────────────────────────────────────────────────┤ │  LAYER 3: IDENTITY CHAIN                                │ │  Chronological hash chain of attestations               │ │  Anchored to Bitcoin blockchain                          │ ├──────────────────────────────────────────────────┤ │  LAYER 2: TRUST GRAPH                                   │ │  Weighted graph of mutual attestations                   │ │  Propagates through social network                       │ ├──────────────────────────────────────────────────┤ │  LAYER 1: VALIDATION THREADS                            │ │  Individual evidence streams: behavioral, relational,    │ │  economic, institutional, biometric                      │ └──────────────────────────────────────────────────┘ |
| :---- |

# **4\. Validation Thread Model**

Identity is established through multiple independent evidence streams called validation threads. No single thread is authoritative. The threads are:

## **4.1 Device Continuity Thread**

Every citizen's mobile device generates a continuous behavioral record: movement patterns, interaction timing, application usage, typing cadence, magnetic signature, accelerometer profiles, and geolocation continuity. This record is processed locally on-device into a zero-knowledge behavioral proof, the raw data never leaves the device.

The behavioral proof answers: "Is this the same continuous individual who has been operating this device over an extended period?" It is tamper-evident because behavioral patterns are deeply individual and extremely difficult to fake continuously. You cannot sell your behavioral continuity the way you can sell a government document.

## **4.2 Legacy Document Thread**

Government-issued identity documents contribute to an Autonym as evidence, not authority. The document attests that at some point, a government institution believed this person existed with these attributes. Legacy documents are strong bootstrap evidence but weak ongoing evidence. They can be forged, stolen, or revoked. Their contribution to the identity rope decreases over time relative to threads that generate continuous evidence.

## **4.3 Economic Presence Thread**

Continuous economic participation, utility bill payments, rent payments, subscription services, tax filings, employment payroll records, constitutes strong evidence of ongoing presence and economic activity. This thread is difficult to fake at scale because it requires real resources, and it is generated by third parties with independent incentives to maintain accurate records.

## **4.4 Relationship Graph Thread**

Every person who knows the citizen can sign their identity with their own Autonym CA. The value of an attestation depends on the strength of the attesting identity. An attestation from a citizen with a deep, long-established Autonym carries more weight than one from a newly registered participant. This is the fractal property: the identity web is self-similar at every scale.

## **4.5 Community Participation Thread**

Participation in governance, voluntary organizations, trade associations, neighborhood groups, and civic institutions contributes to identity through institutional attestations. This thread is particularly valuable for establishing social embeddedness that distinguishes genuine community members from synthetic identities.

## **4.6 Biometric Continuity Thread**

Physical biometrics, fingerprint, facial geometry, iris pattern, voice signature, contribute to identity continuity when voluntarily enrolled. Autonym biometric data is stored locally in a cryptographic commitment that allows zero-knowledge proof of biometric match without transmitting the biometric itself. Biometric threads are strong but not required.

# **5\. The Rope Metaphor: Composing Certainty from Uncertainty**

## **5.1 The Rope**

A single thread is insufficient to establish identity and insufficient to destroy it. The combination of many threads forms a rope whose strength is the product of its composition. No single cut is fatal. An adversary who steals your government ID has cut one thread. The rope continues to hold because the remaining threads are independently sufficient for the required confidence level.

This is the inverse of the legacy system, where a single revocation, a citizenship stripping, a platform ban, a bank account freeze, can sever the identity entirely.

## **5.2 Confidence Thresholds**

| Application | Confidence Level | Minimum Threads |
| :---- | :---- | :---- |
| Anonymous forum access | Proof of personhood | Device continuity sufficient |
| Local community voting | Low-medium | 3+ threads recommended |
| Employment verification | Medium | 5+ threads across categories |
| Property transaction | High | 7+ threads, Bitcoin anchor required |
| Governance participation | High | Full rope recommended |

## **5.3 Temporal Dynamics**

The rope strengthens over time. A newly registered Autonym consists of bootstrap threads and is relatively weak. As the citizen accumulates months and years of behavioral continuity, relationship attestations, and economic presence, the rope grows stronger. Attacking a long-established identity is much harder than attacking a new one. The cost of constructing a fake identity with deep history is prohibitive.

# **6\. Zero-Knowledge Identity Proof**

## **6.1 The Privacy Principle**

A citizen should be able to prove they are who they claim to be without revealing anything beyond what is necessary for the specific interaction. Disclosure is the citizen's choice, not the verifier's demand.

## **6.2 What Can Be Proven Without Disclosure**

Using ZKP constructions (zk-SNARKs or zk-STARKs), an Autonym holder can prove:

* **Proof of personhood:** I am a unique, validated human

* **Threshold proof:** My identity rope exceeds confidence level X

* **Attribute proof:** I am over 18 without revealing birthdate or identity

* **Membership proof:** I am a member of community Y without revealing which member

* **Continuity proof:** My identity has been continuously active for Z years without revealing when

* **Relationship proof:** I am known by at least N validated citizens without revealing who

## **6.3 Selective Disclosure**

When more information is genuinely necessary, citizens can selectively disclose specific threads while keeping others private. A citizen applying for a job can reveal their employment history thread and professional attestations while keeping family relationships, medical threads, and location history private.

# **7\. The Identity Chain and Longest Chain Consensus**

## **7.1 Chain Structure**

Each Autonym is an append-only cryptographic chain. Every attestation received or issued is hashed with the prior attestation's hash in chronological sequence, identical in structure to how each Bitcoin block encodes its predecessor. The chain is anchored to the Bitcoin blockchain periodically.

## **7.2 The Longest Valid Chain Wins**

When two identity records conflict, for example, if an adversary attempts to construct a parallel identity chain using stolen credentials, the resolution mechanism is: the longest valid chain wins.

"Longest" is measured by a weighted function of: chronological depth, thread diversity, attestation weight, behavioral continuity, and economic evidence. A legitimate citizen who has been continuously accumulating their identity for years will have a chain that an adversary cannot plausibly replicate retroactively. Historical depth cannot be faked cheaply.

## **7.3 Fork Resolution**

If a fork in an identity chain is detected, both chains are flagged as disputed, the holder of the longer chain is treated as primary, attestors who signed the shorter chain are notified and can re-attest, and the shorter chain is quarantined pending review. The citizen can challenge the resolution through the governance layer.

# **8\. Trust Propagation Model**

## **8.1 Transitive Trust**

Trust in Autonym is transitive but attenuated. Direct acquaintances carry more weight than friends-of-friends. The attenuation function:

| trust(A ← C via B) \= trust(A ← B) × trust(B ← C) × attenuation\_factor |
| :---- |

Where attenuation\_factor \< 1 for each hop. Trust beyond 3-4 hops becomes negligible.

## **8.2 Trust Graph Properties**

* No single hub: attestation has a cost (attesting party's reputation is at stake), so graphs are naturally distributed

* Community clustering: trust is denser within communities than between them

* Attack resistance: disrupting the trust graph requires compromising many nodes simultaneously

# **9\. Sybil Resistance**

## **9.1 Resistance Through Cost**

A Sybil attack is the creation of many fake identities by a single adversary to gain disproportionate influence. Autonym resists Sybil attacks through cost, not central authority. Creating an Autonym that meets meaningful confidence thresholds requires:

* Continuous device operation over months or years (behavioral continuity)

* Real resource expenditure (utility bills, rent, purchases) for economic presence

* Real relationships with other validated citizens (relationship attestations)

* Real bitcoin fees for chain anchoring

Each has a real cost. Multiplying by the number of fake identities needed to meaningfully influence governance makes the attack economically prohibitive. This is analogous to Bitcoin's Sybil resistance through proof of work.

## **9.2 The Dynamic Key Property**

A citizen's Autonym private key is dynamic; it evolves continuously based on behavioral continuity inputs. Even if an adversary obtains a point-in-time copy of a citizen's key material, that material becomes stale quickly. The legitimate citizen's continuously evolving key diverges from the stolen snapshot. Making long-term impersonation effectively impossible without being the legitimate citizen.

## **9.3 The Enrollment Oracle**

Every mechanism in this paper, and every economic mechanism in the Mesh Republic whitepaper, ultimately rests on a single gate: when an Autonym first crosses the validation threshold and presents its first claim, who or what vouched that exactly one living human stands behind it, and what would it have cost to make that vouching false? This gate is the enrollment oracle. It decomposes into four questions with four different answers: humanness, uniqueness, liveness, and genesis.

**Humanness.** Is there a real person here? The validation thread model of Sections 4 and 5 answers this directly: six independent evidence strands, composed into a rope whose confidence exceeds any single strand. Humanness is the problem this architecture was built for, and no additional machinery is required.

**Uniqueness and the Rope-Splitting Attack.** Does this person hold exactly one Autonym? This is the harder question, because validation threads measure depth, not exclusivity. A real human can attempt to grow two ropes by partitioning a real life: one device history on each of two phones, work relationships attested to one identity and neighborhood relationships to the other, two economic trails. Every signal is genuine; only the routing is dishonest. Against the identity system alone this attack is self-defeating, since two partial ropes are simply two weaker identities. It becomes profitable only at the mint, because the citizen stream pays per rope. The enrollment oracle exists to make that profit unreachable.

**Bootstrap: Exclusive Claim on Legacy Credentials.** During the Republic's early life, uniqueness leans on deduplication the legacy world has already paid for. A government identity document, a passport, a national identity number, represents billions of dollars of existing infrastructure whose sole purpose is ensuring one credential per person. Each legacy document may seed exactly one Autonym: the document's identifier is consumed into a global claim set through a per-document nullifier, proven in zero knowledge so the document itself is never disclosed and never stored. This is the surveillance infrastructure judo of Section 11.4 made load-bearing: the legacy system's own deduplication becomes the Republic's bootstrap Sybil defense. Two safeguards apply. Per-issuer weight is capped, so a hostile or corrupted issuer minting fraudulent credentials cannot flood the identity set. And the document path is never mandatory: the edge-case populations of Section 12 retain full document-free enrollment through the ceremony and attestation paths below.

**Steady State: Ceremonies and Staked Attestation.** Legacy credentials taper as native mechanisms deepen. The first native mechanism is the enrollment ceremony: periodic, simultaneous, local gatherings at which attendees mutually attest one another's presence. Physical simultaneity is the one uniqueness proof no cryptography can counterfeit; a body occupies one place at a time, and a citizen cannot attend two ceremonies at once. Citizenship in a mesh republic is conferred where the mesh lives, at a gathering of neighbors. The second mechanism is staked attestation: vouching for an Autonym's threads places the attestor's own reputation and brots at stake. When evidence collision later reveals a duplicate, the same document surfacing in two ropes, the same device continuity feeding two identities, ceremony attendance records that conflict, the duplicate ropes are merged, and every attestor who fed both is slashed. Because evidence is anchored immutably (Section 13), a successful duplication is not a single lie but a conspiracy that must remain undiscovered forever against a permanent record.

**The Enrollment Ratchet.** The oracle's calibration is economic and self-adjusting. The claiming threshold is set so that the cost of growing a second rope to claiming depth exceeds the net present value of the stream it would steal. That value is finite and computable: a stream of m brots per year discounts to roughly m divided by the prevailing discount rate, reduced further by demurrage on any accumulation, so the prize is bounded by construction while the forging cost rises with required depth. The threshold is dynamic in the manner of the anchoring ratchet: measured duplicate-detection rates adjust required depth automatically, with no vote in the loop. Rising fraud raises the bar; sustained clean epochs relax it toward a constitutional floor.

**Liveness.** Streams terminate at death, so the system must observe death without surveilling life. The claim proof itself is the pulse: each epoch claim carries fresh device-continuity and biometric-continuity evidence, locally held and consumed in zero knowledge. Missed epochs pause the stream rather than banking it, so there is no posthumous accrual and no incentive to conceal a death. Community death attestation closes the identity formally; minted balances pass by ordinary inheritance, and the stream itself passes to no one.

**Genesis.** Before a web of trust exists, someone must attest the first attestors. The Republic handles founders the way honest constitutions do: a publicly documented founding ceremony whose participants hold elevated attestation weight that is time-boxed and expires automatically. The founder problem is real in every network's history; the Republic's answer is to make it explicitly temporary rather than quietly permanent (Section 14.1).

**What the Oracle Refuses.** The enrollment oracle does not and may not maintain a global biometric index. One database of every citizen's iris or face is the panopticon this system exists to reject, and it would contradict the thread model's central thesis: that certainty composes from many weak, local, revocable signals rather than one totalizing strong one. Biometric continuity remains what Section 4.6 defines, one thread among six, held on the citizen's own device, consumed only as zero-knowledge attestations, and never aggregated.

**Attack Surface Summary.**

| Attack | Mechanism | What Defeats It |
| :---- | :---- | :---- |
| Rope splitting | One human partitions real signals into two identities | Exclusive legacy-document claim; ceremony simultaneity; attestor slashing on merge; threshold above stream NPV |
| Synthetic person | Fully fabricated identity | Cost of forging six independent thread types exceeds bounded prize (Section 9.1) |
| Identity rental | Paying a real citizen to claim on one's behalf | Claims non-delegable; small per-epoch amounts; duress protocols (Section 14.1) |
| Issuer poisoning | Corrupt credential issuer mints fake documents | Per-issuer weight caps; cross-thread corroboration; taper toward native mechanisms |
| Posthumous farming | Claiming for the dead | Claim-as-liveness-pulse; missed epochs pause; community death attestation |

# **10\. Kudzu Integration: Persistent Associative Memory**

## **10.1 Why Identity Needs Memory**

A static identity document does not learn. An Autonym, by contrast, is a living record that accumulates context over time. The Kudzu biomimetic memory system provides the storage and retrieval substrate for this accumulation.

Kudzu's holographic reduced representation (HRR) architecture, 512-dimensional vectors binding role-filler pairs through circular convolution, allows an Autonym's contextual associations to be stored efficiently and retrieved associatively. The identity does not merely know facts about the citizen; it knows relationships between facts.

## **10.2 Kudzu as Identity Memory Layer**

In the Autonym architecture, a Kudzu hologram acts as the citizen's identity memory agent. It accumulates traces of interactions and attestations with salience scores based on novelty, recency, frequency, and associative strength. 10-minute light cycles process new traces; 6-hour deep cycles rebuild consolidated vectors. Semantic retrieval improves autonomously as the co-occurrence matrix fills in over time.

## **10.3 The Self-Sovereign Memory Property**

Because Kudzu requires no external API dependencies, all computation runs in pure Elixir using its own HRR math, a citizen's identity memory is entirely self-contained. There is no cloud service that stores your identity context. There is no third party that can be served a subpoena for your identity data. The citizen's Kudzu instance runs on their device. The identity lives where the citizen lives.

# **11\. Bootstrapping from the Legacy System**

## **11.1 The Parallel System Strategy**

Autonym does not require the dismantling of legacy identity infrastructure. It is deployed in parallel with existing systems and improves over time as more citizens join and more attestations accumulate. This is the core Mesh Republic principle: the new system emerges from within the legacy system, benefiting from it while gradually replacing it.

## **11.2 Legacy Records as Bootstrap Inputs**

When a new citizen registers an Autonym, they can strengthen their initial chain by importing verifiable attestations from legacy systems: government ID cryptographic hash, utility account verification, employment verification, financial institution attestation, and professional licensing. Each legacy institution participates as a corporate CA, attesting to facts they already verify, without changing their existing operations.

## **11.3 The DMV Beachhead Strategy**

The optimal entry point for Autonym is the identity verification function currently performed by DMVs and passport agencies. These institutions already perform the verification work. Autonym proposes that they additionally issue a cryptographic attestation when they perform their existing verification. This costs the DMV almost nothing. It adds a strong bootstrap attestation to every citizen who interacts with government identity systems.

## **11.4 The Surveillance Infrastructure Judo**

Legacy surveillance infrastructure, the extensive data collection apparatus of commercial entities, financial institutions, and government agencies, becomes a source of identity strength rather than a threat. A citizen who has years of utility payments, tax records, and financial transactions has strong economic presence evidence available to bootstrap their Autonym. The judo principle: use the adversary's strength against them.

# **12\. Edge Cases and Inclusion**

## **12.1 Recent Immigrants**

New arrivals use bootstrap threads from their country of origin, foreign government documents, international employment records, family attestations from network members, to provide initial chain depth. The cost structure prevents bad actors from manufacturing false newcomer identities at scale.

## **12.2 Domestic Abuse Survivors and Witnesses**

Individuals who need to sever their visible identity can establish a new Autonym with a fresh genesis block, seeded by trusted attestors who have verified their circumstances. The old chain does not automatically transfer, protecting the citizen from being located through their identity history.

## **12.3 Whistleblowers**

The ZKP layer handles this directly: proof of personhood without identity revelation. A whistleblower can prove they have a deep, legitimate Autonym, demonstrating they are not a bot, not a foreign agent, not a synthetic identity, without revealing who they are.

# **13\. Bitcoin Anchoring**

Autonym identity chains require periodic anchoring to an immutable external timestamp source to prevent retroactive chain construction. Bitcoin provides the most secure available immutable timestamp through its proof-of-work chain.

Identity chain root hashes are aggregated into the Mesh Republic's checkpoint Merkle root and committed to Bitcoin alongside the Republic's governance records; a single Bitcoin transaction therefore anchors any number of identity chains, making dense anchoring essentially free. Checkpoint cadence follows the security ratchet defined in Section 4.4.7 of the Mesh Republic whitepaper: dense during bootstrap, relaxing only as sustained network security crosses measured thresholds, densifying automatically if security falls, with a constitutional floor of one anchor per year. Chains are additionally anchored at genesis, at significant attestation milestones, and on demand for high-stakes applications. Standalone Autonym deployments outside the Republic anchor their own aggregated roots directly using Bitcoin's OP\_RETURN opcode, under the same cadence rules.

Sybil resistance does not depend on anchoring fees. The cost of forging identities is the cost of accumulating and maintaining the validation threads themselves (Section 9); anchoring's role is to make whatever history exists unforgeable in retrospect. An attacker cannot retroactively construct a deep chain, because depth is measured against Bitcoin timestamps that no one can rewrite.

# **14\. Governance and Constitutional Constraints**

## **14.1 The Constitutional Layer**

Autonym operates within the Mesh Republic's constitutional AI framework. Identity holograms are governed by constitutional constraints they cannot override:

* **Non-surveillance:** An identity hologram cannot report a citizen's activities to any external party without explicit citizen authorization

* **Non-coercion:** An identity hologram cannot be operated under duress; it detects coercion signals and activates duress protocols

* **Minimal disclosure:** An identity hologram defaults to minimum necessary disclosure and requires explicit citizen consent for additional disclosure

* **Portability:** A citizen can always export their complete identity chain and migrate it to a different implementation

* **Non-transferability:** An Autonym is soulbound to its human. It cannot be sold, transferred, inherited, or reassigned; not by its holder, not by any organization, and not by any governance vote. A transferable identity is an account, not an identity. This constraint is absolute.

* **Founder Sunset:** Elevated attestation weight held by genesis-ceremony participants expires automatically at a constitutionally fixed epoch and may not be renewed or transferred by any governance action.

## **14.2 Autonym in Mesh Republic Governance**

Autonym provides the Sybil-resistant personhood layer that makes one-person-one-vote governance meaningful. Without strong identity, any voting system is vulnerable to identity multiplication attacks. Autonym enables weighted governance participation proportional to identity depth, quadratic voting with Sybil resistance, and auditable delegation through the relationship graph.


Each Autonym is its own root certificate authority; trust originates at the citizen and composes outward. Organizations hold composed identities of their own: an organization is a threshold composition of its members' Autonyms, a group of certificate authorities acting as one signer. Composed identities carry full powers of agency (signing, contracting, holding assets, issuing attestations) and zero powers of citizenship: they do not vote, and they do not mint. Certification composes; personhood does not. Two citizens forming an organization create a new signer, never a new soul. Corporate personhood is rejected at the protocol level.

# **15\. Comparison to Existing Systems**

| Property | Government ID | Autonym |
| :---- | :---- | :---- |
| **Trust direction** | Top-down (state grants) | Bottom-up (community validates) |
| **Single point of failure** | Yes (government revocation) | No (distributed threads) |
| **Privacy** | Minimal | ZKP-native |
| **Censorship resistance** | None | High |
| **Requires trust in government** | Yes | No |
| **Self-improving** | No | Yes (accumulates depth) |
| **Sybil resistant** | Yes (centrally enforced) | Yes (cost-based) |

Existing Self-Sovereign Identity (SSI) proposals such as DID and Verifiable Credentials are philosophically aligned but typically lack continuous behavioral continuity threads, longest chain consensus for dispute resolution, integrated biomimetic memory through Kudzu, and a concrete bootstrapping strategy from legacy systems. Autonym can interoperate with DID/VC systems at the legacy bridge layer, treating Verifiable Credentials as one more validation thread.

# **16\. Implementation Roadmap**

| Phase | Deliverables |
| :---- | :---- |
| **Phase 1Months 1-6Foundation** | Core cryptographic library, key generation, hash chain construction, ZKP integration. Device continuity module. Bitcoin anchoring module. Kudzu integration. Reference implementation in Elixir/BEAM. Security audit. |
| **Phase 2Months 7-12Bootstrap** | Legacy document bridge. First corporate CA integrations (utility, employment). Mobile application. ZKP presentation layer. First community pilot deployment. |
| **Phase 3Months 13-24Network Growth** | Trust graph at scale. Governance integration layer. Longest chain dispute resolution. Cross-community attestation protocols. Developer SDK. |
| **Phase 4Months 25+Legacy Displacement** | DMV partnership pilots. Financial institution CA integration. Professional licensing board integration. International identity bridge. Full constitutional constraint enforcement. |

# **17\. Conclusion**

The central authority model of identity has served a useful purpose in a world where strangers needed to trust each other quickly and organic trust networks did not exist across large distances. But it solved the coordination problem by creating a single point of failure and a single point of control, and those structural vulnerabilities are now being exploited routinely by state and corporate actors against the citizens they were meant to serve.

Autonym does not require the legacy system to fail before it can work. It requires only that a critical mass of citizens begin building their identity ropes, accumulating threads, making attestations, establishing behavioral continuity, in parallel with their legacy documents. Over time, the rope becomes stronger than the document. At that point, the document becomes redundant not because anyone took it away, but because it was outcompeted.

This is how the Mesh Republic spreads: not through revolution, but through demonstrated superiority. Like mycelium, like Linux, like Bitcoin, one community at a time, one service at a time, until the day arrives when the legacy system must interoperate with the new one rather than the other way around.

***Identity is not a document. It is a pattern. Autonym makes the pattern sovereign.***

# **Appendix A: Cryptographic Primitives**

| Primitive | Specification |
| :---- | :---- |
| **Signing** | Ed25519 — fast, secure, small key size |
| **Key Agreement** | X25519 (ECDH for hologram-to-hologram communication) |
| **Hash Function** | SHA3-256 for chain links; BLAKE3 for high-performance internal operations |
| **ZKP** | Groth16 zk-SNARKs for compact proofs (mobile-suitable); STARK for post-quantum resistance |
| **Bitcoin Anchoring** | OP\_RETURN with 80-byte payload: identity chain root hash \+ chain length \+ timestamp commitment |
| **Behavioral Fingerprint** | Locality-sensitive hashing of behavioral time series, processed locally on device. Only hash commitment leaves device. |

# **Appendix B: Validation Thread Confidence Weights**

Initial suggested weights (subject to empirical calibration through deployment):

| Thread | Base Weight | Max Weight | Notes |
| :---- | :---- | :---- | :---- |
| Device continuity (\< 3 months) | 0.10 | 0.10 | Bootstrap |
| Device continuity (3-12 months) | 0.15 | 0.20 | Growing |
| Device continuity (\> 1 year) | 0.20 | 0.30 | Mature |
| Legacy government document | 0.15 | 0.15 | Fixed |
| Utility presence (current) | 0.10 | 0.15 | Per utility |
| Employment attestation | 0.10 | 0.15 | Per employer |
| Family relationship attestation | 0.10 | 0.20 | Depth-dependent |
| Community relationship attestation | 0.05 | 0.15 | Per relationship |
| Bitcoin chain anchor (\> 1 year) | 0.10 | 0.10 | Fixed |
| Professional license | 0.05 | 0.10 | Per license |

# **Appendix C: Relation to The Mesh Republic Whitepaper**

Autonym is a component of the larger Mesh Republic framework. The full framework specification, including Mandelbrots, the Bitcoin-anchored governance token, Kudzu biomimetic constitutional AI, Antitrust 2.0 enforcement mechanisms, and philosophical foundations, is available at:

**github.com/meshrepublic/mesh-republic-whitepaper**

Autonym can be deployed independently of the full Mesh Republic framework. It requires only Bitcoin for anchoring and a compatible Kudzu instance for memory. Full governance integration requires the Mandelbrots governance layer.

*This document is a living specification. Contributions, critiques, and implementations are welcome under the terms of the AGPL-3.0 license.*
