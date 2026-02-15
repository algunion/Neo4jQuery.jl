# [Biomedical Knowledge Graph — Case Study](@id biomedical-case-study)

This case study demonstrates building a realistic biomedical knowledge graph
using the Neo4jQuery DSL. It covers schema declarations, node/relationship
creation, and complex analytical queries — with side-by-side comparisons of
**raw Cypher** vs the **Julia DSL**.

The full runnable script is in [`test/biomedical_graph_test.jl`](https://github.com/algunion/Neo4jQuery.jl/blob/main/test/biomedical_graph_test.jl).

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

### Julia DSL

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

Schemas enable **runtime validation** — misspelled properties, missing required fields, and type mismatches are caught immediately.

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

### Julia DSL

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

### Julia DSL

```julia
# Nodes already in scope from @create — @relate uses elementId() automatically
@relate conn brca1 => ASSOCIATED_WITH(score=0.95, source="ClinVar") => breast_cancer

@relate conn trastuzumab => TREATS(efficacy=0.85, evidence_level="1A") => breast_cancer
```

No need to re-match nodes by property. The DSL uses `elementId()` from the returned `Node` objects — zero ambiguity, zero duplication.

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

**Julia DSL:**
```julia
disease_name = "Breast Cancer"
result = @query conn begin
    @match (g:Gene)-[:ASSOCIATED_WITH]->(d:Disease)
    @match (g)-[:ENCODES]->(p:Protein)-[:PARTICIPATES_IN]->(pw:Pathway)
    @where d.name == $disease_name
    @return g.symbol => :gene, p.name => :protein, pw.name => :pathway
    @orderby g.symbol
end access_mode=:read
```

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

**Julia DSL:**
```julia
target_disease = "Breast Cancer"
result = @query conn begin
    @match (drug:Drug)-[:TARGETS]->(prot:Protein)-[:PARTICIPATES_IN]->(pw:Pathway)
    @match (prot2:Protein)-[:PARTICIPATES_IN]->(pw)
    @match (g:Gene)-[:ENCODES]->(prot2)
    @match (g)-[:ASSOCIATED_WITH]->(d:Disease)
    @where d.name == $target_disease
    @return drug.name => :drug, pw.name => :pathway, g.symbol => :gene
    @orderby drug.name
end access_mode=:read
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

**Julia DSL:**
```julia
result = @query conn begin
    @match (pt:Patient)-[dx:DIAGNOSED_WITH]->(d:Disease)
    @optional_match (pt)-[e:ENROLLED_IN]->(ct:ClinicalTrial)
    @return pt.patient_id => :patient, d.name => :disease,
            dx.stage => :stage, ct.trial_id => :trial
    @orderby d.name pt.patient_id
end access_mode=:read
```

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

**Julia DSL:**
```julia
result = @query conn begin
    @match (drug:Drug)-[t:TREATS]->(d:Disease)
    @with d.name => :disease, count(drug) => :drug_count, avg(t.efficacy) => :mean_efficacy
    @where drug_count > 1
    @return disease, drug_count, mean_efficacy
    @orderby drug_count :desc
end access_mode=:read
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

**Julia DSL:**
```julia
result = @query conn begin
    @match (d1:Drug)-[:HAS_SIDE_EFFECT]->(s:Symptom)
    @match (d2:Drug)-[:HAS_SIDE_EFFECT]->(s)
    @where d1.name < d2.name
    @return d1.name => :drug1, d2.name => :drug2, collect(s.name) => :shared_effects
    @orderby d1.name
end access_mode=:read
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

**Julia DSL:**
```julia
pid = "PT-2024-001"
result = @query conn begin
    @match (pt:Patient)-[dx:DIAGNOSED_WITH]->(d:Disease)
    @match (drug:Drug)-[t:TREATS]->(d)
    @where pt.patient_id == $pid
    @optional_match (pt)-[e:ENROLLED_IN]->(ct:ClinicalTrial)
    @optional_match (drug)-[:HAS_SIDE_EFFECT]->(se:Symptom)
    @return d.name => :disease, drug.name => :drug_option,
            t.efficacy => :efficacy, ct.title => :trial,
            collect(se.name) => :side_effects
    @orderby t.efficacy :desc
end access_mode=:read
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

**Julia DSL:**
```julia
min_diseases = 2
result = @query conn begin
    @match (g:Gene)-[a:ASSOCIATED_WITH]->(d:Disease)
    @with g.symbol => :gene, count(d) => :disease_count, collect(d.name) => :diseases
    @where disease_count >= $min_diseases
    @return gene, disease_count, diseases
    @orderby disease_count :desc
end access_mode=:read
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

**Julia DSL:**
```julia
result = @query conn begin
    @match (ph:Physician)-[:LOCATED_AT]->(h:Hospital)
    @return h.name => :hospital, collect(ph.specialty) => :specialties,
            count(ph) => :physician_count
    @orderby physician_count :desc
end access_mode=:read
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

**Julia DSL:**
```julia
result = @query conn begin
    @match (bm:Biomarker)-[:INDICATES]->(d:Disease)
    @match (drug:Drug)-[:TREATS]->(d)
    @return bm.name => :biomarker, d.name => :disease,
            drug.name => :drug, drug.mechanism => :mechanism
    @orderby bm.name drug.name
end access_mode=:read
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

**Julia DSL:**
```julia
result = @query conn begin
    @match (bm:Biomarker)-[:INDICATES]->(d:Disease)
    @match (g:Gene)-[:ASSOCIATED_WITH]->(d)
    @match (g)-[:ENCODES]->(p:Protein)-[:PARTICIPATES_IN]->(pw:Pathway)
    @return bm.name => :biomarker, d.name => :disease,
            g.symbol => :gene, p.name => :protein, pw.name => :pathway
    @orderby d.name g.symbol
end access_mode=:read
```

A **five-hop traversal** across the entire knowledge base — expressed as readable Julia.

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

**Julia DSL:**
```julia
adverse_events = [
    Dict("drug_name" => "Trastuzumab", "event" => "Cardiotoxicity", "grade" => 2),
    Dict("drug_name" => "Erlotinib", "event" => "Rash", "grade" => 1),
    Dict("drug_name" => "Pembrolizumab", "event" => "Pneumonitis", "grade" => 3),
    Dict("drug_name" => "Olaparib", "event" => "Anemia", "grade" => 2),
]

result = @query conn begin
    @unwind $adverse_events => :ae
    @match (drug:Drug)
    @where drug.name == ae.drug_name
    @create (drug)-[:REPORTED_AE]->(event:AdverseEvent)
    @set event.name = ae.event
    @set event.grade = ae.grade
    @return drug.name => :drug, event.name => :event, event.grade => :grade
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

**Julia DSL:**
```julia
result = @query conn begin
    @match (g:Gene)-[:ASSOCIATED_WITH]->(d:Disease)
    @where startswith(g.chromosome, "17") && d.category == "Oncology"
    @return g.symbol => :gene, g.chromosome => :chr, d.name => :disease
    @orderby g.symbol
end access_mode=:read
```

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

**Julia DSL:**
```julia
result = @query conn begin
    @match (drug:Drug)-[t:TREATS]->(d:Disease)
    @with d, count(drug) => :n_drugs, avg(t.efficacy) => :avg_eff
    @match (g:Gene)-[:ASSOCIATED_WITH]->(d)
    @return d.name => :disease, n_drugs, avg_eff,
            count(g) => :n_genes
    @orderby n_drugs :desc
end access_mode=:read
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

**Julia DSL:**
```julia
result = @query conn begin
    @match (pub:Publication)-[:PUBLISHED_IN]->(d:Disease)
    @match (drug:Drug)-[:TREATS]->(d)
    @with pub, d, collect(drug.name) => :drugs
    @return pub.title => :publication, pub.journal => :journal,
            d.name => :disease, drugs
    @orderby pub.year :desc
end access_mode=:read
```

---

## Key takeaways

| Aspect                | Raw Cypher                                   | Julia DSL                               |
| :-------------------- | :------------------------------------------- | :-------------------------------------- |
| **Injection safety**  | Manual parameterisation                      | Automatic — `$var` captures safely      |
| **Schema validation** | None built-in                                | `@node`/`@rel` with runtime checks      |
| **Node references**   | Re-match by property                         | Direct variable reuse via `elementId()` |
| **Operator mapping**  | Cypher-specific (`<>`, `AND`, `STARTS WITH`) | Julia-native (`!=`, `&&`, `startswith`) |
| **Return aliases**    | `expr AS alias`                              | `expr => :alias`                        |
| **Compile-time**      | String at runtime                            | Cypher assembled at macro expansion     |
| **Composability**     | String concatenation                         | Structured macro blocks                 |

The DSL compiles to **identical Cypher** at macro expansion time — there is zero runtime overhead for query construction. Only parameter values are captured at runtime.
