# [Biomedical Knowledge Graph — Case Study](@id biomedical-case-study)

This case study demonstrates building a realistic biomedical knowledge graph
using the Neo4jQuery DSL. It covers schema declarations, node/relationship
creation, and complex analytical queries — with side-by-side comparisons of
**raw Cypher** vs the **`@cypher` DSL**.

Neo4jQuery provides the `@cypher` macro — a unified query interface that uses:
- **Function-call clause syntax**: `where()`, `ret()`, `order()`, `take()`, `with()`, `create()`, `merge()`, `optional()`, `unwind()`, …
- **`>>` chain patterns** (recommended): `p::Person >> r::KNOWS >> q::Person`
- **Arrow patterns** (also supported): `(p:Person)-[r:KNOWS]->(q:Person)`
- **Auto-SET** from property assignments: `p.age = $val`
- **Comprehension form**: `@cypher conn [p.name for p in Person if p.age > 25]`

The macro compiles to **Cypher** at macro expansion time — zero runtime overhead for query construction. Only parameter values are captured at runtime.

!!! note "Unified pattern syntax in `@cypher`"
    The `@cypher` macro uses `>>` chains as its **single, canonical pattern language** — for queries, mutations, merges, everything. The same `>>` syntax works in `create()`, `merge()`, `optional()`, `match()`, and bare implicit MATCH. Arrow syntax (`-[]->`), while backward-compatible, is not needed.

The full runnable scripts are:
- [`test/biomedical_graph_test.jl`](https://github.com/algunion/Neo4jQuery.jl/blob/main/test/biomedical_graph_test.jl) — `@create` / `@relate` standalone macro examples
- [`test/biomedical_graph_dsl_test.jl`](https://github.com/algunion/Neo4jQuery.jl/blob/main/test/biomedical_graph_dsl_test.jl) — `@cypher` DSL examples

---

## Domain model

The graph models a clinical/biomedical knowledge base with **12 node types**
and **17 relationship types**:

| Node Labels   | Relationship Types           |
| :------------ | :--------------------------- |
| Disease       | ASSOCIATED\_WITH             |
| Gene          | TARGETS                      |
| Protein       | INHIBITS                     |
| Drug          | ENCODES                      |
| ClinicalTrial | PARTICIPATES\_IN             |
| Patient       | DIAGNOSED\_WITH              |
| Hospital      | ENROLLED\_IN                 |
| Physician     | TREATS                       |
| Pathway       | PRESCRIBED\_BY               |
| Symptom       | LOCATED\_AT                  |
| Biomarker     | PRESENTS\_WITH               |
| Publication   | INDICATES, PUBLISHED\_IN     |
|               | EXPRESSES, HAS\_SIDE\_EFFECT |
|               | INTERACTS\_WITH              |

---

## 1. Schema declarations

### Raw Cypher

Cypher has no built-in schema declarations. You rely on conventions and documentation:

```cypher
// No schema — just hope everyone remembers the properties
CREATE (d:Disease {name: "Breast Cancer", icd10_code: "C50", category: "Oncology", chronic: true})
// Oops, someone writes: CREATE (d:Disease {naam: "Lung Cancer"})  — no error
```

### `@cypher` DSL — schema declarations

```julia
using Neo4jQuery

@node Disease begin
    name::String
    icd10_code::String
    category::String
    chronic::Bool
end

@node Gene begin
    symbol::String
    full_name::String
    chromosome::String
    locus::String = ""       # optional, with default
end

@node Protein begin
    uniprot_id::String
    name::String
    molecular_weight::Float64
    function_desc::String = ""
end

@node Drug begin
    name::String
    trade_name::String
    mechanism::String
    approved_year::Int
    phase::String = "approved"
end

@node Patient begin
    patient_id::String
    age::Int
    sex::String
    ethnicity::String = ""
end

# Relationships get schemas too
@rel ASSOCIATED_WITH begin
    score::Float64
    source::String
end

@rel TARGETS begin
    action::String
    binding_affinity::Float64 = 0.0
end

@rel TREATS begin
    efficacy::Float64
    evidence_level::String
end

@rel DIAGNOSED_WITH begin
    diagnosis_date::String
    stage::String = ""
end
```

Schemas enable **runtime validation** — misspelled properties, missing required fields, and type mismatches are caught immediately. The `@cypher` macro uses the same schema registry.

---

## 2. Creating nodes

### Raw Cypher

```cypher
CREATE (d:Disease {name: 'Breast Cancer', icd10_code: 'C50', category: 'Oncology', chronic: true})
RETURN d

CREATE (g:Gene {symbol: 'BRCA1', full_name: 'BRCA1 DNA Repair Associated',
                chromosome: '17q21.31', locus: '17q21'})
RETURN g

CREATE (drug:Drug {name: 'Trastuzumab', trade_name: 'Herceptin',
                   mechanism: 'HER2 monoclonal antibody', approved_year: 1998})
RETURN drug
```

### Julia DSL — `@create` macro

```julia
breast_cancer = @create conn Disease(
    name="Breast Cancer",
    icd10_code="C50",
    category="Oncology",
    chronic=true
)

brca1 = @create conn Gene(
    symbol="BRCA1", full_name="BRCA1 DNA Repair Associated",
    chromosome="17q21.31", locus="17q21"
)

trastuzumab = @create conn Drug(
    name="Trastuzumab", trade_name="Herceptin",
    mechanism="HER2 monoclonal antibody", approved_year=1998
)
```

Each call returns a `Node` object you can use directly to create relationships.

### Julia DSL — `@cypher` macro

```julia
breast_cancer = let
    r = @cypher conn begin
        create(d::Disease)
        d.name = "Breast Cancer"
        d.icd10_code = "C50"
        d.category = "Oncology"
        d.chronic = true
        ret(d)
    end
    r[1].d
end

brca1 = let
    r = @cypher conn begin
        create(g::Gene)
        g.symbol = "BRCA1"
        g.full_name = "BRCA1 DNA Repair Associated"
        g.chromosome = "17q21.31"
        g.locus = "17q21"
        ret(g)
    end
    r[1].g
end

trastuzumab = let
    r = @cypher conn begin
        create(d::Drug)
        d.name = "Trastuzumab"
        d.trade_name = "Herceptin"
        d.mechanism = "HER2 monoclonal antibody"
        d.approved_year = 1998
        ret(d)
    end
    r[1].d
end
```

The `@cypher` approach uses `create()` + property assignments (`d.name = "..."`) which compile to `CREATE (d:Disease) SET d.name = '...'`. Properties are set via auto-SET detection.

For creating nodes, `create(d::Disease)` is a single-node pattern. For creating relationships, `create()` takes a `>>` chain (see next section).

---

## 3. Creating relationships

### Raw Cypher

```cypher
// Need to match nodes by some property first
MATCH (g:Gene {symbol: 'BRCA1'}), (d:Disease {name: 'Breast Cancer'})
CREATE (g)-[r:ASSOCIATED_WITH {score: 0.95, source: 'ClinVar'}]->(d)
RETURN r

MATCH (drug:Drug {name: 'Trastuzumab'}), (d:Disease {name: 'Breast Cancer'})
CREATE (drug)-[r:TREATS {efficacy: 0.85, evidence_level: '1A'}]->(d)
RETURN r
```

### Julia DSL — `@relate` macro

```julia
# Nodes already in scope from @create — @relate uses elementId() automatically
@relate conn brca1 => ASSOCIATED_WITH(score=0.95, source="ClinVar") => breast_cancer

@relate conn trastuzumab => TREATS(efficacy=0.85, evidence_level="1A") => breast_cancer
```

No need to re-match nodes by property. The DSL uses `elementId()` from the returned `Node` objects — zero ambiguity, zero duplication.

### Julia DSL — `@cypher` macro

```julia
# Match nodes by property, then create the relationship with >> chain
@cypher conn begin
    match(g::Gene, d::Disease)
    where(g.symbol == "BRCA1", d.name == "Breast Cancer")
    create(g >> r::ASSOCIATED_WITH >> d)
    r.score = 0.95
    r.source = "ClinVar"
    ret(r)
end

@cypher conn begin
    match(drug::Drug, d::Disease)
    where(drug.name == "Trastuzumab", d.name == "Breast Cancer")
    create(drug >> r::TREATS >> d)
    r.efficacy = 0.85
    r.evidence_level = "1A"
    ret(r)
end
```

The same `>>` pattern syntax used in queries also works in `create()`, `merge()`, and `optional()`. Relationship properties are set via auto-SET.

---

## 4. Complex queries — side by side

### 4.1 Multi-hop: Gene → Protein → Pathway for a disease

**Raw Cypher:**
```cypher
MATCH (g:Gene)-[:ASSOCIATED_WITH]->(d:Disease {name: 'Breast Cancer'})
MATCH (g)-[:ENCODES]->(p:Protein)-[:PARTICIPATES_IN]->(pw:Pathway)
RETURN g.symbol AS gene, p.name AS protein, pw.name AS pathway
ORDER BY g.symbol
```

**`@cypher` DSL:**
```julia
disease_name = "Breast Cancer"
result = @cypher conn begin
    g::Gene >> ::ASSOCIATED_WITH >> d::Disease
    g >> ::ENCODES >> p::Protein >> ::PARTICIPATES_IN >> pw::Pathway
    where(d.name == $disease_name)
    ret(g.symbol => :gene, p.name => :protein, pw.name => :pathway)
    order(g.symbol)
end
```

The `>>` chains are the canonical pattern syntax in `@cypher` — they work uniformly for queries, mutations, and everything in between. Bare patterns become implicit `MATCH` clauses.

---

### 4.2 Drug repurposing — shared pathway targets

**Raw Cypher:**
```cypher
MATCH (drug:Drug)-[:TARGETS]->(prot:Protein)-[:PARTICIPATES_IN]->(pw:Pathway)
MATCH (prot2:Protein)-[:PARTICIPATES_IN]->(pw)
MATCH (g:Gene)-[:ENCODES]->(prot2)
MATCH (g)-[:ASSOCIATED_WITH]->(d:Disease {name: 'Breast Cancer'})
RETURN drug.name AS drug, pw.name AS pathway, g.symbol AS gene
ORDER BY drug.name
```

**`@cypher` DSL:**
```julia
target_disease = "Breast Cancer"
result = @cypher conn begin
    drug::Drug >> ::TARGETS >> prot::Protein >> ::PARTICIPATES_IN >> pw::Pathway
    prot2::Protein >> ::PARTICIPATES_IN >> pw
    g::Gene >> ::ENCODES >> prot2
    g >> ::ASSOCIATED_WITH >> d::Disease
    where(d.name == $target_disease)
    ret(drug.name => :drug, pw.name => :pathway, g.symbol => :gene)
    order(drug.name)
end
```

---

### 4.3 Patient cohort analysis with optional trial enrollment

**Raw Cypher:**
```cypher
MATCH (pt:Patient)-[dx:DIAGNOSED_WITH]->(d:Disease)
OPTIONAL MATCH (pt)-[e:ENROLLED_IN]->(ct:ClinicalTrial)
RETURN pt.patient_id AS patient, d.name AS disease,
       dx.stage AS stage, ct.trial_id AS trial
ORDER BY d.name, pt.patient_id
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    pt::Patient >> dx::DIAGNOSED_WITH >> d::Disease
    optional(pt >> e::ENROLLED_IN >> ct::ClinicalTrial)
    ret(pt.patient_id => :patient, d.name => :disease,
        dx.stage => :stage, ct.trial_id => :trial)
    order(d.name, pt.patient_id)
end
```

`optional()` maps to `OPTIONAL MATCH` and accepts the same `>>` chain patterns.

---

### 4.4 Aggregation: drug count and average efficacy per disease

**Raw Cypher:**
```cypher
MATCH (drug:Drug)-[t:TREATS]->(d:Disease)
WITH d.name AS disease, count(drug) AS drug_count, avg(t.efficacy) AS mean_efficacy
WHERE drug_count > 1
RETURN disease, drug_count, mean_efficacy
ORDER BY drug_count DESC
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    drug::Drug >> t::TREATS >> d::Disease
    with(d.name => :disease, count(drug) => :drug_count, avg(t.efficacy) => :mean_efficacy)
    where(drug_count > 1)
    ret(disease, drug_count, mean_efficacy)
    order(drug_count, :desc)
end
```

---

### 4.5 Side effect overlap between drugs

**Raw Cypher:**
```cypher
MATCH (d1:Drug)-[:HAS_SIDE_EFFECT]->(s:Symptom)
MATCH (d2:Drug)-[:HAS_SIDE_EFFECT]->(s)
WHERE d1.name < d2.name
RETURN d1.name AS drug1, d2.name AS drug2, collect(s.name) AS shared_effects
ORDER BY d1.name
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    d1::Drug >> ::HAS_SIDE_EFFECT >> s::Symptom
    d2::Drug >> ::HAS_SIDE_EFFECT >> s
    where(d1.name < d2.name)
    ret(d1.name => :drug1, d2.name => :drug2, collect(s.name) => :shared_effects)
    order(d1.name)
end
```

---

### 4.6 Full patient journey — diagnosis to treatment

**Raw Cypher:**
```cypher
MATCH (pt:Patient {patient_id: $pid})-[dx:DIAGNOSED_WITH]->(d:Disease)
MATCH (drug:Drug)-[t:TREATS]->(d)
OPTIONAL MATCH (pt)-[e:ENROLLED_IN]->(ct:ClinicalTrial)
OPTIONAL MATCH (drug)-[:HAS_SIDE_EFFECT]->(se:Symptom)
RETURN d.name AS disease, drug.name AS drug_option,
       t.efficacy AS efficacy, ct.title AS trial,
       collect(se.name) AS side_effects
ORDER BY t.efficacy DESC
```

**`@cypher` DSL:**
```julia
pid = "PT-2024-001"
result = @cypher conn begin
    pt::Patient >> dx::DIAGNOSED_WITH >> d::Disease
    drug::Drug >> t::TREATS >> d
    where(pt.patient_id == $pid)
    optional(pt >> e::ENROLLED_IN >> ct::ClinicalTrial)
    optional(drug >> ::HAS_SIDE_EFFECT >> se::Symptom)
    ret(d.name => :disease, drug.name => :drug_option,
        t.efficacy => :efficacy, ct.title => :trial,
        collect(se.name) => :side_effects)
    order(t.efficacy, :desc)
end
```

---

### 4.7 Genes with multiple disease associations

**Raw Cypher:**
```cypher
MATCH (g:Gene)-[a:ASSOCIATED_WITH]->(d:Disease)
WITH g.symbol AS gene, count(d) AS disease_count, collect(d.name) AS diseases
WHERE disease_count >= $min_diseases
RETURN gene, disease_count, diseases
ORDER BY disease_count DESC
```

**`@cypher` DSL:**
```julia
min_diseases = 2
result = @cypher conn begin
    g::Gene >> a::ASSOCIATED_WITH >> d::Disease
    with(g.symbol => :gene, count(d) => :disease_count, collect(d.name) => :diseases)
    where(disease_count >= $min_diseases)
    ret(gene, disease_count, diseases)
    order(disease_count, :desc)
end
```

---

### 4.8 Hospital physician coverage

**Raw Cypher:**
```cypher
MATCH (ph:Physician)-[:LOCATED_AT]->(h:Hospital)
RETURN h.name AS hospital, collect(ph.specialty) AS specialties,
       count(ph) AS physician_count
ORDER BY physician_count DESC
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    ph::Physician >> ::LOCATED_AT >> h::Hospital
    ret(h.name => :hospital, collect(ph.specialty) => :specialties,
        count(ph) => :physician_count)
    order(physician_count, :desc)
end
```

---

### 4.9 Biomarker-guided treatment selection

**Raw Cypher:**
```cypher
MATCH (bm:Biomarker)-[:INDICATES]->(d:Disease)
MATCH (drug:Drug)-[:TREATS]->(d)
RETURN bm.name AS biomarker, d.name AS disease,
       drug.name AS drug, drug.mechanism AS mechanism
ORDER BY bm.name, drug.name
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    bm::Biomarker >> ::INDICATES >> d::Disease
    drug::Drug >> ::TREATS >> d
    ret(bm.name => :biomarker, d.name => :disease,
        drug.name => :drug, drug.mechanism => :mechanism)
    order(bm.name, drug.name)
end
```

---

### 4.10 Full knowledge chain: Biomarker → Disease → Gene → Protein → Pathway

**Raw Cypher:**
```cypher
MATCH (bm:Biomarker)-[:INDICATES]->(d:Disease)
MATCH (g:Gene)-[:ASSOCIATED_WITH]->(d)
MATCH (g)-[:ENCODES]->(p:Protein)-[:PARTICIPATES_IN]->(pw:Pathway)
RETURN bm.name AS biomarker, d.name AS disease,
       g.symbol AS gene, p.name AS protein, pw.name AS pathway
ORDER BY d.name, g.symbol
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    bm::Biomarker >> ::INDICATES >> d::Disease
    g::Gene >> ::ASSOCIATED_WITH >> d
    g >> ::ENCODES >> p::Protein >> ::PARTICIPATES_IN >> pw::Pathway
    ret(bm.name => :biomarker, d.name => :disease,
        g.symbol => :gene, p.name => :protein, pw.name => :pathway)
    order(d.name, g.symbol)
end
```

A **five-hop traversal** across the entire knowledge base — expressed as readable Julia. The `>>` chains make the directionality explicit and composable.

---

### 4.11 Batch insert with UNWIND

**Raw Cypher:**
```cypher
UNWIND $adverse_events AS ae
MATCH (drug:Drug)
WHERE drug.name = ae.drug_name
CREATE (drug)-[:REPORTED_AE]->(event:AdverseEvent)
SET event.name = ae.event, event.grade = ae.grade
RETURN drug.name AS drug, event.name AS event, event.grade AS grade
```

**`@cypher` DSL:**
```julia
adverse_events = [
    Dict("drug_name" => "Trastuzumab", "event" => "Cardiotoxicity", "grade" => 2),
    Dict("drug_name" => "Erlotinib", "event" => "Rash", "grade" => 1),
    Dict("drug_name" => "Pembrolizumab", "event" => "Pneumonitis", "grade" => 3),
    Dict("drug_name" => "Olaparib", "event" => "Anemia", "grade" => 2),
]

result = @cypher conn begin
    unwind($adverse_events => :ae)
    drug::Drug
    where(drug.name == ae.drug_name)
    create(drug >> ::REPORTED_AE >> event::AdverseEvent)
    event.name = ae.event
    event.grade = ae.grade
    ret(drug.name => :drug, event.name => :event, event.grade => :grade)
end
```

---

### 4.12 Complex WHERE with string functions

**Raw Cypher:**
```cypher
MATCH (g:Gene)-[:ASSOCIATED_WITH]->(d:Disease)
WHERE g.chromosome STARTS WITH '17' AND d.category = 'Oncology'
RETURN g.symbol AS gene, g.chromosome AS chr, d.name AS disease
ORDER BY g.symbol
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    g::Gene >> ::ASSOCIATED_WITH >> d::Disease
    where(startswith(g.chromosome, "17"), d.category == "Oncology")
    ret(g.symbol => :gene, g.chromosome => :chr, d.name => :disease)
    order(g.symbol)
end
```

Multi-condition `where()` auto-ANDs conditions — no need for `&&`.

---

### 4.13 WITH pipeline — treatment landscape

**Raw Cypher:**
```cypher
MATCH (drug:Drug)-[t:TREATS]->(d:Disease)
WITH d, count(drug) AS n_drugs, avg(t.efficacy) AS avg_eff
MATCH (g:Gene)-[:ASSOCIATED_WITH]->(d)
RETURN d.name AS disease, n_drugs, avg_eff, count(g) AS n_genes
ORDER BY n_drugs DESC
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    drug::Drug >> t::TREATS >> d::Disease
    with(d, count(drug) => :n_drugs, avg(t.efficacy) => :avg_eff)
    g::Gene >> ::ASSOCIATED_WITH >> d
    ret(d.name => :disease, n_drugs, avg_eff, count(g) => :n_genes)
    order(n_drugs, :desc)
end
```

---

### 4.14 Publication → Disease knowledge network

**Raw Cypher:**
```cypher
MATCH (pub:Publication)-[:PUBLISHED_IN]->(d:Disease)
MATCH (drug:Drug)-[:TREATS]->(d)
WITH pub, d, collect(drug.name) AS drugs
RETURN pub.title AS publication, pub.journal AS journal,
       d.name AS disease, drugs
ORDER BY pub.year DESC
```

**`@cypher` DSL:**
```julia
result = @cypher conn begin
    pub::Publication >> ::PUBLISHED_IN >> d::Disease
    drug::Drug >> ::TREATS >> d
    with(pub, d, collect(drug.name) => :drugs)
    ret(pub.title => :publication, pub.journal => :journal,
        d.name => :disease, drugs)
    order(pub.year, :desc)
end
```

---

## Key takeaways

| Aspect                | Raw Cypher                         | `@cypher` DSL                                     |
| :-------------------- | :--------------------------------- | :------------------------------------------------ |
| **Injection safety**  | Manual parameterisation            | Automatic — `$var` captures safely                |
| **Schema validation** | None built-in                      | `@node`/`@rel` with runtime checks                |
| **Node references**   | Re-match by property               | `match()` + `where()` + `create()`, or `@relate`  |
| **Patterns**          | `(p:Person)-[r:KNOWS]->(q:Person)` | `p::Person >> r::KNOWS >> q::Person` (everywhere) |
| **Clauses**           | Cypher keywords                    | `where()`, `ret()`, `order()`, `take()`           |
| **Operator mapping**  | `<>`, `AND`, `STARTS WITH`         | `!=`, `&&`, `startswith` (Julia-native)           |
| **Return aliases**    | `expr AS alias`                    | `expr => :alias`                                  |
| **Mutations**         | `CREATE`, `SET`                    | `create()` + auto-SET assignments                 |
| **OPTIONAL MATCH**    | `OPTIONAL MATCH`                   | `optional()`                                      |
| **Compile-time**      | String at runtime                  | Cypher assembled at macro expansion               |

The `@cypher` macro compiles to **identical Cypher** at macro expansion time — there is zero runtime overhead for query construction. Only parameter values are captured at runtime. The `>>` syntax works uniformly across queries (`MATCH`), mutations (`CREATE`, `MERGE`), and `OPTIONAL MATCH` — one pattern language for everything.
