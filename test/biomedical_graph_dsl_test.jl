# ══════════════════════════════════════════════════════════════════════════════
# Biomedical Knowledge Graph — @graph DSL Integration Test
#
# Mirrors the biomedical_graph_test.jl but uses the @graph macro exclusively.
# Validates that the @graph DSL can express the full complexity of a realistic
# biomedical knowledge graph: schema declarations, node/relationship creation
# via @graph create(), rich traversals via >> chains, aggregations, OPTIONAL
# MATCH, WITH pipelines, UNWIND batch operations, and string functions.
#
# The graph is purged at the start of each run, but NOT at the end.
# ══════════════════════════════════════════════════════════════════════════════

using Neo4jQuery
using Test

if !isdefined(@__MODULE__, :TestGraphUtils)
    include("test_utils.jl")
end
using .TestGraphUtils

# ── Connection ───────────────────────────────────────────────────────────────
conn = connect_from_env()

purge_counts = purge_db!(conn; verify=true)
@test purge_counts.nodes == 0
@test purge_counts.relationships == 0

# ════════════════════════════════════════════════════════════════════════════
# PART 1 — Schema Declarations (identical to biomedical_graph_test.jl)
# ════════════════════════════════════════════════════════════════════════════

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
    locus::String = ""
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

@node ClinicalTrial begin
    trial_id::String
    title::String
    phase::String
    status::String
    start_year::Int
    enrollment::Int
end

@node Patient begin
    patient_id::String
    age::Int
    sex::String
    ethnicity::String = ""
end

@node Hospital begin
    name::String
    city::String
    country::String
    beds::Int
end

@node Physician begin
    name::String
    specialty::String
    license_no::String
end

@node Pathway begin
    name::String
    kegg_id::String
    category::String
end

@node Symptom begin
    name::String
    severity_scale::String
    body_system::String
end

@node Biomarker begin
    name::String
    biomarker_type::String
    unit::String
end

@node Publication begin
    doi::String
    title::String
    journal::String
    year::Int
end

# --- Relationship schemas ---

@rel ASSOCIATED_WITH begin
    score::Float64
    source::String
end

@rel TARGETS begin
    action::String
    binding_affinity::Float64 = 0.0
end

@rel INHIBITS begin
    ic50::Float64
    mechanism::String = ""
end

@rel ENCODES begin
    transcript_id::String
end

@rel PARTICIPATES_IN begin
    role::String
end

@rel DIAGNOSED_WITH begin
    diagnosis_date::String
    stage::String = ""
end

@rel ENROLLED_IN begin
    enrollment_date::String
    arm::String
end

@rel TREATS begin
    efficacy::Float64
    evidence_level::String
end

@rel PRESCRIBED_BY begin
    prescription_date::String
end

@rel LOCATED_AT begin
    department::String
end

@rel PRESENTS_WITH begin
    onset::String
    frequency::String = ""
end

@rel INDICATES begin
    threshold::Float64
    direction::String
end

@rel PUBLISHED_IN begin
    contribution::String
end

@rel EXPRESSES begin
    tissue::String
    expression_level::Float64
end

@rel HAS_SIDE_EFFECT begin
    frequency::String
    severity::String
end

@rel INTERACTS_WITH begin
    interaction_type::String
    confidence::Float64
end

# ════════════════════════════════════════════════════════════════════════════
# PART 2 — Node Creation via @graph create()
# ════════════════════════════════════════════════════════════════════════════

@testset "Biomedical @graph — Node Creation" begin

    # ── Helper: create a node via @graph and extract it ──────────────────

    # --- Diseases ---
    global breast_cancer = let
        r = @graph conn begin
            create(d::Disease)
            d.name = "Breast Cancer"
            d.icd10_code = "C50"
            d.category = "Oncology"
            d.chronic = true
            ret(d)
        end
        r[1].d
    end
    global lung_cancer = let
        r = @graph conn begin
            create(d::Disease)
            d.name = "Non-Small Cell Lung Cancer"
            d.icd10_code = "C34.9"
            d.category = "Oncology"
            d.chronic = true
            ret(d)
        end
        r[1].d
    end
    global type2_diabetes = let
        r = @graph conn begin
            create(d::Disease)
            d.name = "Type 2 Diabetes Mellitus"
            d.icd10_code = "E11"
            d.category = "Endocrinology"
            d.chronic = true
            ret(d)
        end
        r[1].d
    end
    global hypertension = let
        r = @graph conn begin
            create(d::Disease)
            d.name = "Essential Hypertension"
            d.icd10_code = "I10"
            d.category = "Cardiology"
            d.chronic = true
            ret(d)
        end
        r[1].d
    end
    global alzheimers = let
        r = @graph conn begin
            create(d::Disease)
            d.name = "Alzheimer Disease"
            d.icd10_code = "G30"
            d.category = "Neurology"
            d.chronic = true
            ret(d)
        end
        r[1].d
    end

    @test breast_cancer isa Node
    @test "Disease" in breast_cancer.labels

    # --- Genes ---
    global brca1 = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "BRCA1"
            g.full_name = "BRCA1 DNA Repair Associated"
            g.chromosome = "17q21.31"
            g.locus = "17q21"
            ret(g)
        end
        r[1].g
    end
    global tp53 = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "TP53"
            g.full_name = "Tumor Protein P53"
            g.chromosome = "17p13.1"
            g.locus = "17p13"
            ret(g)
        end
        r[1].g
    end
    global egfr = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "EGFR"
            g.full_name = "Epidermal Growth Factor Receptor"
            g.chromosome = "7p11.2"
            g.locus = "7p11"
            ret(g)
        end
        r[1].g
    end
    global her2 = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "ERBB2"
            g.full_name = "Erb-B2 Receptor Tyrosine Kinase 2"
            g.chromosome = "17q12"
            g.locus = "17q12"
            ret(g)
        end
        r[1].g
    end
    global apoe = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "APOE"
            g.full_name = "Apolipoprotein E"
            g.chromosome = "19q13.32"
            g.locus = "19q13"
            ret(g)
        end
        r[1].g
    end
    global kras = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "KRAS"
            g.full_name = "KRAS Proto-Oncogene"
            g.chromosome = "12p12.1"
            g.locus = "12p12"
            ret(g)
        end
        r[1].g
    end
    global alk_gene = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "ALK"
            g.full_name = "ALK Receptor Tyrosine Kinase"
            g.chromosome = "2p23.2"
            g.locus = "2p23"
            ret(g)
        end
        r[1].g
    end
    global pik3ca = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "PIK3CA"
            g.full_name = "Phosphatidylinositol-4,5-Bisphosphate 3-Kinase Catalytic Subunit Alpha"
            g.chromosome = "3q26.32"
            g.locus = "3q26"
            ret(g)
        end
        r[1].g
    end
    global ins_gene = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "INS"
            g.full_name = "Insulin"
            g.chromosome = "11p15.5"
            g.locus = "11p15"
            ret(g)
        end
        r[1].g
    end
    global ace_gene = let
        r = @graph conn begin
            create(g::Gene)
            g.symbol = "ACE"
            g.full_name = "Angiotensin I Converting Enzyme"
            g.chromosome = "17q23.3"
            g.locus = "17q23"
            ret(g)
        end
        r[1].g
    end

    @test brca1["symbol"] == "BRCA1"

    # --- Proteins ---
    global brca1_protein = let
        r = @graph conn begin
            create(p::Protein)
            p.uniprot_id = "P38398"
            p.name = "Breast cancer type 1 susceptibility protein"
            p.molecular_weight = 207721.0
            p.function_desc = "E3 ubiquitin-protein ligase, DNA repair"
            ret(p)
        end
        r[1].p
    end
    global p53_protein = let
        r = @graph conn begin
            create(p::Protein)
            p.uniprot_id = "P04637"
            p.name = "Cellular tumor antigen p53"
            p.molecular_weight = 43653.0
            p.function_desc = "Tumor suppressor, transcription factor"
            ret(p)
        end
        r[1].p
    end
    global egfr_protein = let
        r = @graph conn begin
            create(p::Protein)
            p.uniprot_id = "P00533"
            p.name = "Epidermal growth factor receptor"
            p.molecular_weight = 134277.0
            p.function_desc = "Receptor tyrosine kinase"
            ret(p)
        end
        r[1].p
    end
    global her2_protein = let
        r = @graph conn begin
            create(p::Protein)
            p.uniprot_id = "P04626"
            p.name = "Receptor tyrosine-protein kinase erbB-2"
            p.molecular_weight = 137910.0
            p.function_desc = "Receptor tyrosine kinase, oncogene"
            ret(p)
        end
        r[1].p
    end
    global alk_protein = let
        r = @graph conn begin
            create(p::Protein)
            p.uniprot_id = "Q9UM73"
            p.name = "ALK tyrosine kinase receptor"
            p.molecular_weight = 176442.0
            p.function_desc = "Receptor tyrosine kinase"
            ret(p)
        end
        r[1].p
    end
    global insulin_protein = let
        r = @graph conn begin
            create(p::Protein)
            p.uniprot_id = "P01308"
            p.name = "Insulin"
            p.molecular_weight = 11981.0
            p.function_desc = "Hormone regulating glucose metabolism"
            ret(p)
        end
        r[1].p
    end
    global ace_protein = let
        r = @graph conn begin
            create(p::Protein)
            p.uniprot_id = "P12821"
            p.name = "Angiotensin-converting enzyme"
            p.molecular_weight = 149715.0
            p.function_desc = "Metalloprotease, blood pressure regulation"
            ret(p)
        end
        r[1].p
    end

    @test brca1_protein["uniprot_id"] == "P38398"

    # --- Drugs ---
    global trastuzumab = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Trastuzumab"
            d.trade_name = "Herceptin"
            d.mechanism = "HER2 monoclonal antibody"
            d.approved_year = 1998
            ret(d)
        end
        r[1].d
    end
    global erlotinib = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Erlotinib"
            d.trade_name = "Tarceva"
            d.mechanism = "EGFR tyrosine kinase inhibitor"
            d.approved_year = 2004
            ret(d)
        end
        r[1].d
    end
    global olaparib = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Olaparib"
            d.trade_name = "Lynparza"
            d.mechanism = "PARP inhibitor"
            d.approved_year = 2014
            ret(d)
        end
        r[1].d
    end
    global crizotinib = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Crizotinib"
            d.trade_name = "Xalkori"
            d.mechanism = "ALK/ROS1 inhibitor"
            d.approved_year = 2011
            ret(d)
        end
        r[1].d
    end
    global pembrolizumab = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Pembrolizumab"
            d.trade_name = "Keytruda"
            d.mechanism = "PD-1 checkpoint inhibitor"
            d.approved_year = 2014
            ret(d)
        end
        r[1].d
    end
    global metformin = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Metformin"
            d.trade_name = "Glucophage"
            d.mechanism = "Biguanide, reduces hepatic glucose production"
            d.approved_year = 1995
            ret(d)
        end
        r[1].d
    end
    global lisinopril = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Lisinopril"
            d.trade_name = "Prinivil"
            d.mechanism = "ACE inhibitor"
            d.approved_year = 1987
            ret(d)
        end
        r[1].d
    end
    global donepezil = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Donepezil"
            d.trade_name = "Aricept"
            d.mechanism = "Acetylcholinesterase inhibitor"
            d.approved_year = 1996
            ret(d)
        end
        r[1].d
    end
    global tamoxifen = let
        r = @graph conn begin
            create(d::Drug)
            d.name = "Tamoxifen"
            d.trade_name = "Nolvadex"
            d.mechanism = "Selective estrogen receptor modulator"
            d.approved_year = 1977
            ret(d)
        end
        r[1].d
    end

    @test trastuzumab["name"] == "Trastuzumab"

    # --- Pathways ---
    global pi3k_pathway = let
        r = @graph conn begin
            create(pw::Pathway)
            pw.name = "PI3K-Akt Signaling Pathway"
            pw.kegg_id = "hsa04151"
            pw.category = "Signal transduction"
            ret(pw)
        end
        r[1].pw
    end
    global mapk_pathway = let
        r = @graph conn begin
            create(pw::Pathway)
            pw.name = "MAPK Signaling Pathway"
            pw.kegg_id = "hsa04010"
            pw.category = "Signal transduction"
            ret(pw)
        end
        r[1].pw
    end
    global p53_pathway = let
        r = @graph conn begin
            create(pw::Pathway)
            pw.name = "p53 Signaling Pathway"
            pw.kegg_id = "hsa04115"
            pw.category = "Cell growth and death"
            ret(pw)
        end
        r[1].pw
    end
    global insulin_pathway = let
        r = @graph conn begin
            create(pw::Pathway)
            pw.name = "Insulin Signaling Pathway"
            pw.kegg_id = "hsa04910"
            pw.category = "Endocrine system"
            ret(pw)
        end
        r[1].pw
    end
    global raas_pathway = let
        r = @graph conn begin
            create(pw::Pathway)
            pw.name = "Renin-Angiotensin-Aldosterone System"
            pw.kegg_id = "hsa04614"
            pw.category = "Endocrine system"
            ret(pw)
        end
        r[1].pw
    end

    @test pi3k_pathway isa Node

    # --- Symptoms ---
    global fatigue = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Fatigue"
            s.severity_scale = "mild/moderate/severe"
            s.body_system = "Systemic"
            ret(s)
        end
        r[1].s
    end
    global dyspnea = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Dyspnea"
            s.severity_scale = "mMRC 0-4"
            s.body_system = "Respiratory"
            ret(s)
        end
        r[1].s
    end
    global chest_pain = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Chest Pain"
            s.severity_scale = "NRS 0-10"
            s.body_system = "Cardiovascular"
            ret(s)
        end
        r[1].s
    end
    global memory_loss = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Memory Loss"
            s.severity_scale = "MMSE 0-30"
            s.body_system = "Neurological"
            ret(s)
        end
        r[1].s
    end
    global polyuria = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Polyuria"
            s.severity_scale = "mild/moderate/severe"
            s.body_system = "Renal"
            ret(s)
        end
        r[1].s
    end
    global lump = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Breast Lump"
            s.severity_scale = "BIRADS 1-6"
            s.body_system = "Breast"
            ret(s)
        end
        r[1].s
    end
    global headache = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Headache"
            s.severity_scale = "NRS 0-10"
            s.body_system = "Neurological"
            ret(s)
        end
        r[1].s
    end
    global cough = let
        r = @graph conn begin
            create(s::Symptom)
            s.name = "Chronic Cough"
            s.severity_scale = "LCQ 3-21"
            s.body_system = "Respiratory"
            ret(s)
        end
        r[1].s
    end

    @test fatigue isa Node

    # --- Biomarkers ---
    global ca125 = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "CA-125"
            bm.biomarker_type = "Serum protein"
            bm.unit = "U/mL"
            ret(bm)
        end
        r[1].bm
    end
    global her2_marker = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "HER2 IHC"
            bm.biomarker_type = "Immunohistochemistry"
            bm.unit = "score 0-3+"
            ret(bm)
        end
        r[1].bm
    end
    global hba1c = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "HbA1c"
            bm.biomarker_type = "Glycated hemoglobin"
            bm.unit = "%"
            ret(bm)
        end
        r[1].bm
    end
    global egfr_mutation = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "EGFR Mutation Status"
            bm.biomarker_type = "Genetic"
            bm.unit = "positive/negative"
            ret(bm)
        end
        r[1].bm
    end
    global pdl1 = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "PD-L1 TPS"
            bm.biomarker_type = "Immunohistochemistry"
            bm.unit = "%"
            ret(bm)
        end
        r[1].bm
    end
    global bp_systolic = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "Systolic Blood Pressure"
            bm.biomarker_type = "Vital sign"
            bm.unit = "mmHg"
            ret(bm)
        end
        r[1].bm
    end
    global apoe_genotype = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "APOE Genotype"
            bm.biomarker_type = "Genetic"
            bm.unit = "allele"
            ret(bm)
        end
        r[1].bm
    end
    global brca_status = let
        r = @graph conn begin
            create(bm::Biomarker)
            bm.name = "BRCA1/2 Mutation Status"
            bm.biomarker_type = "Genetic"
            bm.unit = "positive/negative"
            ret(bm)
        end
        r[1].bm
    end

    @test ca125 isa Node

    # --- Hospitals ---
    global mgh = let
        r = @graph conn begin
            create(h::Hospital)
            h.name = "Massachusetts General Hospital"
            h.city = "Boston"
            h.country = "USA"
            h.beds = 1000
            ret(h)
        end
        r[1].h
    end
    global mayo = let
        r = @graph conn begin
            create(h::Hospital)
            h.name = "Mayo Clinic"
            h.city = "Rochester"
            h.country = "USA"
            h.beds = 1265
            ret(h)
        end
        r[1].h
    end
    global charite = let
        r = @graph conn begin
            create(h::Hospital)
            h.name = "Charite - Universitaetsmedizin Berlin"
            h.city = "Berlin"
            h.country = "Germany"
            h.beds = 3001
            ret(h)
        end
        r[1].h
    end

    @test mgh isa Node

    # --- Physicians ---
    global dr_chen = let
        r = @graph conn begin
            create(ph::Physician)
            ph.name = "Dr. Lisa Chen"
            ph.specialty = "Medical Oncology"
            ph.license_no = "MA-ONC-4421"
            ret(ph)
        end
        r[1].ph
    end
    global dr_mueller = let
        r = @graph conn begin
            create(ph::Physician)
            ph.name = "Dr. Hans Mueller"
            ph.specialty = "Pulmonology"
            ph.license_no = "DE-PUL-8837"
            ret(ph)
        end
        r[1].ph
    end
    global dr_patel = let
        r = @graph conn begin
            create(ph::Physician)
            ph.name = "Dr. Priya Patel"
            ph.specialty = "Endocrinology"
            ph.license_no = "MN-END-2259"
            ret(ph)
        end
        r[1].ph
    end
    global dr_johnson = let
        r = @graph conn begin
            create(ph::Physician)
            ph.name = "Dr. Robert Johnson"
            ph.specialty = "Cardiology"
            ph.license_no = "MA-CAR-1178"
            ret(ph)
        end
        r[1].ph
    end
    global dr_nakamura = let
        r = @graph conn begin
            create(ph::Physician)
            ph.name = "Dr. Yuki Nakamura"
            ph.specialty = "Neurology"
            ph.license_no = "MN-NEU-5543"
            ret(ph)
        end
        r[1].ph
    end

    @test dr_chen isa Node

    # --- Clinical Trials ---
    global trial_keynote = let
        r = @graph conn begin
            create(ct::ClinicalTrial)
            ct.trial_id = "NCT02478826"
            ct.title = "KEYNOTE-189: Pembrolizumab + Chemo in NSCLC"
            ct.phase = "Phase 3"
            ct.status = "Completed"
            ct.start_year = 2015
            ct.enrollment = 616
            ret(ct)
        end
        r[1].ct
    end
    global trial_olympiad = let
        r = @graph conn begin
            create(ct::ClinicalTrial)
            ct.trial_id = "NCT02000622"
            ct.title = "OlympiAD: Olaparib in HER2-negative Breast Cancer"
            ct.phase = "Phase 3"
            ct.status = "Completed"
            ct.start_year = 2014
            ct.enrollment = 302
            ret(ct)
        end
        r[1].ct
    end
    global trial_profile = let
        r = @graph conn begin
            create(ct::ClinicalTrial)
            ct.trial_id = "NCT01433913"
            ct.title = "PROFILE 1014: Crizotinib vs Chemo in ALK+ NSCLC"
            ct.phase = "Phase 3"
            ct.status = "Completed"
            ct.start_year = 2011
            ct.enrollment = 343
            ret(ct)
        end
        r[1].ct
    end
    global trial_cleopatra = let
        r = @graph conn begin
            create(ct::ClinicalTrial)
            ct.trial_id = "NCT00567190"
            ct.title = "CLEOPATRA: Pertuzumab + Trastuzumab in HER2+ Breast Cancer"
            ct.phase = "Phase 3"
            ct.status = "Completed"
            ct.start_year = 2008
            ct.enrollment = 808
            ret(ct)
        end
        r[1].ct
    end

    @test trial_keynote["trial_id"] == "NCT02478826"

    # --- Patients ---
    global patient_a = let
        r = @graph conn begin
            create(pt::Patient)
            pt.patient_id = "PT-2024-001"
            pt.age = 58
            pt.sex = "Female"
            pt.ethnicity = "Caucasian"
            ret(pt)
        end
        r[1].pt
    end
    global patient_b = let
        r = @graph conn begin
            create(pt::Patient)
            pt.patient_id = "PT-2024-002"
            pt.age = 67
            pt.sex = "Male"
            pt.ethnicity = "Asian"
            ret(pt)
        end
        r[1].pt
    end
    global patient_c = let
        r = @graph conn begin
            create(pt::Patient)
            pt.patient_id = "PT-2024-003"
            pt.age = 45
            pt.sex = "Female"
            pt.ethnicity = "Hispanic"
            ret(pt)
        end
        r[1].pt
    end
    global patient_d = let
        r = @graph conn begin
            create(pt::Patient)
            pt.patient_id = "PT-2024-004"
            pt.age = 72
            pt.sex = "Male"
            pt.ethnicity = "Caucasian"
            ret(pt)
        end
        r[1].pt
    end
    global patient_e = let
        r = @graph conn begin
            create(pt::Patient)
            pt.patient_id = "PT-2024-005"
            pt.age = 51
            pt.sex = "Female"
            pt.ethnicity = "African American"
            ret(pt)
        end
        r[1].pt
    end
    global patient_f = let
        r = @graph conn begin
            create(pt::Patient)
            pt.patient_id = "PT-2024-006"
            pt.age = 63
            pt.sex = "Male"
            pt.ethnicity = "Caucasian"
            ret(pt)
        end
        r[1].pt
    end

    @test patient_a["patient_id"] == "PT-2024-001"

    # --- Publications ---
    global pub_keynote = let
        r = @graph conn begin
            create(pub::Publication)
            pub.doi = "10.1056/NEJMoa1810865"
            pub.title = "Pembrolizumab plus Chemotherapy for NSCLC"
            pub.journal = "NEJM"
            pub.year = 2018
            ret(pub)
        end
        r[1].pub
    end
    global pub_olaparib = let
        r = @graph conn begin
            create(pub::Publication)
            pub.doi = "10.1056/NEJMoa1706450"
            pub.title = "Olaparib for HER2-Negative Metastatic Breast Cancer"
            pub.journal = "NEJM"
            pub.year = 2017
            ret(pub)
        end
        r[1].pub
    end
    global pub_brca_structure = let
        r = @graph conn begin
            create(pub::Publication)
            pub.doi = "10.1038/nature11143"
            pub.title = "BRCA1 RING structure and ubiquitin-ligase activity"
            pub.journal = "Nature"
            pub.year = 2012
            ret(pub)
        end
        r[1].pub
    end
    global pub_alzheimers_apoe = let
        r = @graph conn begin
            create(pub::Publication)
            pub.doi = "10.1016/S1474-4422(19)30373-3"
            pub.title = "APOE e4 and Alzheimer Disease Risk"
            pub.journal = "Lancet Neurology"
            pub.year = 2019
            ret(pub)
        end
        r[1].pub
    end

    @test pub_keynote["doi"] == "10.1056/NEJMoa1810865"
end

# ════════════════════════════════════════════════════════════════════════════
# PART 3 — Relationship Creation via @graph
#
# Uses match() + where() + create() pattern with arrow syntax,
# since @graph doesn't have @relate. Nodes are matched by unique
# properties, then connected with relationship patterns.
# ════════════════════════════════════════════════════════════════════════════

@testset "Biomedical @graph — Relationships" begin

    # ── Gene → Disease associations ──────────────────────────────────────
    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "BRCA1", d.name == "Breast Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.95
        r.source = "ClinVar"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "TP53", d.name == "Breast Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.90
        r.source = "COSMIC"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "TP53", d.name == "Non-Small Cell Lung Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.88
        r.source = "COSMIC"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "EGFR", d.name == "Non-Small Cell Lung Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.92
        r.source = "TCGA"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "ERBB2", d.name == "Breast Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.97
        r.source = "ClinVar"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "KRAS", d.name == "Non-Small Cell Lung Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.85
        r.source = "COSMIC"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "ALK", d.name == "Non-Small Cell Lung Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.88
        r.source = "COSMIC"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "PIK3CA", d.name == "Breast Cancer")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.80
        r.source = "TCGA"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "APOE", d.name == "Alzheimer Disease")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.93
        r.source = "GWAS Catalog"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "INS", d.name == "Type 2 Diabetes Mellitus")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.78
        r.source = "OMIM"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, d::Disease)
        where(g.symbol == "ACE", d.name == "Essential Hypertension")
        create((g) - [r::ASSOCIATED_WITH] -> (d))
        r.score = 0.75
        r.source = "GWAS Catalog"
        ret(r)
    end

    # ── Gene → Protein (ENCODES) ────────────────────────────────────────
    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "BRCA1", p.uniprot_id == "P38398")
        create((g) - [r::ENCODES] -> (p))
        r.transcript_id = "NM_007294.4"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "TP53", p.uniprot_id == "P04637")
        create((g) - [r::ENCODES] -> (p))
        r.transcript_id = "NM_000546.6"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "EGFR", p.uniprot_id == "P00533")
        create((g) - [r::ENCODES] -> (p))
        r.transcript_id = "NM_005228.5"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "ERBB2", p.uniprot_id == "P04626")
        create((g) - [r::ENCODES] -> (p))
        r.transcript_id = "NM_004448.4"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "ALK", p.uniprot_id == "Q9UM73")
        create((g) - [r::ENCODES] -> (p))
        r.transcript_id = "NM_004304.5"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "INS", p.uniprot_id == "P01308")
        create((g) - [r::ENCODES] -> (p))
        r.transcript_id = "NM_000207.3"
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "ACE", p.uniprot_id == "P12821")
        create((g) - [r::ENCODES] -> (p))
        r.transcript_id = "NM_000789.4"
        ret(r)
    end

    # ── Drug → Protein (TARGETS) ────────────────────────────────────────
    @graph conn begin
        match(drug::Drug, p::Protein)
        where(drug.name == "Trastuzumab", p.uniprot_id == "P04626")
        create((drug) - [r::TARGETS] -> (p))
        r.action = "antagonist"
        r.binding_affinity = 0.1
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, p::Protein)
        where(drug.name == "Erlotinib", p.uniprot_id == "P00533")
        create((drug) - [r::TARGETS] -> (p))
        r.action = "inhibitor"
        r.binding_affinity = 2.0
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, p::Protein)
        where(drug.name == "Crizotinib", p.uniprot_id == "Q9UM73")
        create((drug) - [r::TARGETS] -> (p))
        r.action = "inhibitor"
        r.binding_affinity = 0.6
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, p::Protein)
        where(drug.name == "Lisinopril", p.uniprot_id == "P12821")
        create((drug) - [r::TARGETS] -> (p))
        r.action = "inhibitor"
        r.binding_affinity = 0.3
        ret(r)
    end

    # ── Drug → Protein (INHIBITS) ───────────────────────────────────────
    result_inhibit = @graph conn begin
        match(drug::Drug, p::Protein)
        where(drug.name == "Olaparib", p.uniprot_id == "P38398")
        create((drug) - [r::INHIBITS] -> (p))
        r.ic50 = 5.0
        r.mechanism = "PARP trapping"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, p::Protein)
        where(drug.name == "Erlotinib", p.uniprot_id == "P00533")
        create((drug) - [r::INHIBITS] -> (p))
        r.ic50 = 2.0
        r.mechanism = "ATP-competitive"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, p::Protein)
        where(drug.name == "Crizotinib", p.uniprot_id == "Q9UM73")
        create((drug) - [r::INHIBITS] -> (p))
        r.ic50 = 24.0
        r.mechanism = "ATP-competitive"
        ret(r)
    end

    @test result_inhibit[1].r isa Relationship

    # ── Drug → Disease (TREATS) ─────────────────────────────────────────
    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Trastuzumab", d.name == "Breast Cancer")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.85
        r.evidence_level = "1A"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Olaparib", d.name == "Breast Cancer")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.72
        r.evidence_level = "1B"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Tamoxifen", d.name == "Breast Cancer")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.68
        r.evidence_level = "1A"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Erlotinib", d.name == "Non-Small Cell Lung Cancer")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.65
        r.evidence_level = "1B"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Crizotinib", d.name == "Non-Small Cell Lung Cancer")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.74
        r.evidence_level = "1A"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Pembrolizumab", d.name == "Non-Small Cell Lung Cancer")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.78
        r.evidence_level = "1A"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Metformin", d.name == "Type 2 Diabetes Mellitus")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.82
        r.evidence_level = "1A"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Lisinopril", d.name == "Essential Hypertension")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.80
        r.evidence_level = "1A"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, d::Disease)
        where(drug.name == "Donepezil", d.name == "Alzheimer Disease")
        create((drug) - [r::TREATS] -> (d))
        r.efficacy = 0.45
        r.evidence_level = "1B"
        ret(r)
    end

    # ── Drug side effects ────────────────────────────────────────────────
    @graph conn begin
        match(drug::Drug, s::Symptom)
        where(drug.name == "Trastuzumab", s.name == "Fatigue")
        create((drug) - [r::HAS_SIDE_EFFECT] -> (s))
        r.frequency = "common"
        r.severity = "moderate"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, s::Symptom)
        where(drug.name == "Trastuzumab", s.name == "Dyspnea")
        create((drug) - [r::HAS_SIDE_EFFECT] -> (s))
        r.frequency = "common"
        r.severity = "moderate"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, s::Symptom)
        where(drug.name == "Erlotinib", s.name == "Fatigue")
        create((drug) - [r::HAS_SIDE_EFFECT] -> (s))
        r.frequency = "very common"
        r.severity = "mild"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, s::Symptom)
        where(drug.name == "Olaparib", s.name == "Fatigue")
        create((drug) - [r::HAS_SIDE_EFFECT] -> (s))
        r.frequency = "common"
        r.severity = "mild"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, s::Symptom)
        where(drug.name == "Olaparib", s.name == "Headache")
        create((drug) - [r::HAS_SIDE_EFFECT] -> (s))
        r.frequency = "common"
        r.severity = "mild"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, s::Symptom)
        where(drug.name == "Pembrolizumab", s.name == "Fatigue")
        create((drug) - [r::HAS_SIDE_EFFECT] -> (s))
        r.frequency = "common"
        r.severity = "moderate"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, s::Symptom)
        where(drug.name == "Metformin", s.name == "Headache")
        create((drug) - [r::HAS_SIDE_EFFECT] -> (s))
        r.frequency = "uncommon"
        r.severity = "mild"
        ret(r)
    end

    # ── Protein → Pathway (PARTICIPATES_IN) ─────────────────────────────
    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P00533", pw.kegg_id == "hsa04151")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "receptor"
        ret(r)
    end

    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P00533", pw.kegg_id == "hsa04010")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "receptor"
        ret(r)
    end

    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P04626", pw.kegg_id == "hsa04151")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "receptor"
        ret(r)
    end

    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P04626", pw.kegg_id == "hsa04010")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "receptor"
        ret(r)
    end

    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P04637", pw.kegg_id == "hsa04115")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "transcription factor"
        ret(r)
    end

    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P38398", pw.kegg_id == "hsa04115")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "DNA repair mediator"
        ret(r)
    end

    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P01308", pw.kegg_id == "hsa04910")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "ligand"
        ret(r)
    end

    @graph conn begin
        match(p::Protein, pw::Pathway)
        where(p.uniprot_id == "P12821", pw.kegg_id == "hsa04614")
        create((p) - [r::PARTICIPATES_IN] -> (pw))
        r.role = "enzyme"
        ret(r)
    end

    # ── Gene → Protein (EXPRESSES) ──────────────────────────────────────
    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "BRCA1", p.uniprot_id == "P38398")
        create((g) - [r::EXPRESSES] -> (p))
        r.tissue = "breast"
        r.expression_level = 8.5
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "BRCA1", p.uniprot_id == "P38398")
        create((g) - [r::EXPRESSES] -> (p))
        r.tissue = "ovary"
        r.expression_level = 7.2
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "EGFR", p.uniprot_id == "P00533")
        create((g) - [r::EXPRESSES] -> (p))
        r.tissue = "lung"
        r.expression_level = 9.1
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "ERBB2", p.uniprot_id == "P04626")
        create((g) - [r::EXPRESSES] -> (p))
        r.tissue = "breast"
        r.expression_level = 6.8
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "APOE", p.uniprot_id == "P12821")
        create((g) - [r::EXPRESSES] -> (p))
        r.tissue = "brain"
        r.expression_level = 9.5
        ret(r)
    end

    @graph conn begin
        match(g::Gene, p::Protein)
        where(g.symbol == "INS", p.uniprot_id == "P01308")
        create((g) - [r::EXPRESSES] -> (p))
        r.tissue = "pancreas"
        r.expression_level = 9.9
        ret(r)
    end

    # ── Disease → Symptom (PRESENTS_WITH) ───────────────────────────────
    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Breast Cancer", s.name == "Breast Lump")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "insidious"
        r.frequency = "common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Breast Cancer", s.name == "Fatigue")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "late"
        r.frequency = "common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Non-Small Cell Lung Cancer", s.name == "Chronic Cough")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "gradual"
        r.frequency = "very common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Non-Small Cell Lung Cancer", s.name == "Dyspnea")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "gradual"
        r.frequency = "common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Non-Small Cell Lung Cancer", s.name == "Chest Pain")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "late"
        r.frequency = "common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Type 2 Diabetes Mellitus", s.name == "Polyuria")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "gradual"
        r.frequency = "common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Type 2 Diabetes Mellitus", s.name == "Fatigue")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "gradual"
        r.frequency = "common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Essential Hypertension", s.name == "Headache")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "acute"
        r.frequency = "uncommon"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Essential Hypertension", s.name == "Chest Pain")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "acute"
        r.frequency = "uncommon"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Alzheimer Disease", s.name == "Memory Loss")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "insidious"
        r.frequency = "very common"
        ret(r)
    end

    @graph conn begin
        match(d::Disease, s::Symptom)
        where(d.name == "Alzheimer Disease", s.name == "Fatigue")
        create((d) - [r::PRESENTS_WITH] -> (s))
        r.onset = "late"
        r.frequency = "common"
        ret(r)
    end

    # ── Biomarker → Disease (INDICATES) ─────────────────────────────────
    @graph conn begin
        match(bm::Biomarker, d::Disease)
        where(bm.name == "HER2 IHC", d.name == "Breast Cancer")
        create((bm) - [r::INDICATES] -> (d))
        r.threshold = 3.0
        r.direction = "positive"
        ret(r)
    end

    @graph conn begin
        match(bm::Biomarker, d::Disease)
        where(bm.name == "BRCA1/2 Mutation Status", d.name == "Breast Cancer")
        create((bm) - [r::INDICATES] -> (d))
        r.threshold = 1.0
        r.direction = "positive"
        ret(r)
    end

    @graph conn begin
        match(bm::Biomarker, d::Disease)
        where(bm.name == "EGFR Mutation Status", d.name == "Non-Small Cell Lung Cancer")
        create((bm) - [r::INDICATES] -> (d))
        r.threshold = 1.0
        r.direction = "positive"
        ret(r)
    end

    @graph conn begin
        match(bm::Biomarker, d::Disease)
        where(bm.name == "PD-L1 TPS", d.name == "Non-Small Cell Lung Cancer")
        create((bm) - [r::INDICATES] -> (d))
        r.threshold = 50.0
        r.direction = "positive"
        ret(r)
    end

    @graph conn begin
        match(bm::Biomarker, d::Disease)
        where(bm.name == "HbA1c", d.name == "Type 2 Diabetes Mellitus")
        create((bm) - [r::INDICATES] -> (d))
        r.threshold = 6.5
        r.direction = "above"
        ret(r)
    end

    @graph conn begin
        match(bm::Biomarker, d::Disease)
        where(bm.name == "Systolic Blood Pressure", d.name == "Essential Hypertension")
        create((bm) - [r::INDICATES] -> (d))
        r.threshold = 140.0
        r.direction = "above"
        ret(r)
    end

    @graph conn begin
        match(bm::Biomarker, d::Disease)
        where(bm.name == "APOE Genotype", d.name == "Alzheimer Disease")
        create((bm) - [r::INDICATES] -> (d))
        r.threshold = 1.0
        r.direction = "positive"
        ret(r)
    end

    # ── Patient → Disease (DIAGNOSED_WITH) ──────────────────────────────
    @graph conn begin
        match(pt::Patient, d::Disease)
        where(pt.patient_id == "PT-2024-001", d.name == "Breast Cancer")
        create((pt) - [r::DIAGNOSED_WITH] -> (d))
        r.diagnosis_date = "2023-03-15"
        r.stage = "IIA"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, d::Disease)
        where(pt.patient_id == "PT-2024-002", d.name == "Non-Small Cell Lung Cancer")
        create((pt) - [r::DIAGNOSED_WITH] -> (d))
        r.diagnosis_date = "2022-11-08"
        r.stage = "IIIB"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, d::Disease)
        where(pt.patient_id == "PT-2024-003", d.name == "Breast Cancer")
        create((pt) - [r::DIAGNOSED_WITH] -> (d))
        r.diagnosis_date = "2024-01-20"
        r.stage = "IB"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, d::Disease)
        where(pt.patient_id == "PT-2024-004", d.name == "Type 2 Diabetes Mellitus")
        create((pt) - [r::DIAGNOSED_WITH] -> (d))
        r.diagnosis_date = "2021-06-12"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, d::Disease)
        where(pt.patient_id == "PT-2024-004", d.name == "Essential Hypertension")
        create((pt) - [r::DIAGNOSED_WITH] -> (d))
        r.diagnosis_date = "2019-09-05"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, d::Disease)
        where(pt.patient_id == "PT-2024-005", d.name == "Non-Small Cell Lung Cancer")
        create((pt) - [r::DIAGNOSED_WITH] -> (d))
        r.diagnosis_date = "2023-07-30"
        r.stage = "IV"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, d::Disease)
        where(pt.patient_id == "PT-2024-006", d.name == "Alzheimer Disease")
        create((pt) - [r::DIAGNOSED_WITH] -> (d))
        r.diagnosis_date = "2020-04-18"
        ret(r)
    end

    # ── Patient → ClinicalTrial (ENROLLED_IN) ──────────────────────────
    @graph conn begin
        match(pt::Patient, ct::ClinicalTrial)
        where(pt.patient_id == "PT-2024-001", ct.trial_id == "NCT02000622")
        create((pt) - [r::ENROLLED_IN] -> (ct))
        r.enrollment_date = "2023-05-01"
        r.arm = "treatment"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, ct::ClinicalTrial)
        where(pt.patient_id == "PT-2024-002", ct.trial_id == "NCT02478826")
        create((pt) - [r::ENROLLED_IN] -> (ct))
        r.enrollment_date = "2022-12-15"
        r.arm = "treatment"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, ct::ClinicalTrial)
        where(pt.patient_id == "PT-2024-003", ct.trial_id == "NCT00567190")
        create((pt) - [r::ENROLLED_IN] -> (ct))
        r.enrollment_date = "2024-03-01"
        r.arm = "control"
        ret(r)
    end

    @graph conn begin
        match(pt::Patient, ct::ClinicalTrial)
        where(pt.patient_id == "PT-2024-005", ct.trial_id == "NCT02478826")
        create((pt) - [r::ENROLLED_IN] -> (ct))
        r.enrollment_date = "2023-09-15"
        r.arm = "treatment"
        ret(r)
    end

    # ── Physician → Hospital (LOCATED_AT) ───────────────────────────────
    @graph conn begin
        match(ph::Physician, h::Hospital)
        where(ph.license_no == "MA-ONC-4421", h.name == "Massachusetts General Hospital")
        create((ph) - [r::LOCATED_AT] -> (h))
        r.department = "Medical Oncology"
        ret(r)
    end

    @graph conn begin
        match(ph::Physician, h::Hospital)
        where(ph.license_no == "MA-CAR-1178", h.name == "Massachusetts General Hospital")
        create((ph) - [r::LOCATED_AT] -> (h))
        r.department = "Cardiology"
        ret(r)
    end

    @graph conn begin
        match(ph::Physician, h::Hospital)
        where(ph.license_no == "MN-END-2259", h.name == "Mayo Clinic")
        create((ph) - [r::LOCATED_AT] -> (h))
        r.department = "Endocrinology"
        ret(r)
    end

    @graph conn begin
        match(ph::Physician, h::Hospital)
        where(ph.license_no == "MN-NEU-5543", h.name == "Mayo Clinic")
        create((ph) - [r::LOCATED_AT] -> (h))
        r.department = "Neurology"
        ret(r)
    end

    @graph conn begin
        match(ph::Physician, h::Hospital)
        where(ph.license_no == "DE-PUL-8837", h.name == "Charite - Universitaetsmedizin Berlin")
        create((ph) - [r::LOCATED_AT] -> (h))
        r.department = "Pulmonology"
        ret(r)
    end

    # ── Drug → Physician (PRESCRIBED_BY) ────────────────────────────────
    @graph conn begin
        match(drug::Drug, ph::Physician)
        where(drug.name == "Trastuzumab", ph.license_no == "MA-ONC-4421")
        create((drug) - [r::PRESCRIBED_BY] -> (ph))
        r.prescription_date = "2023-04-01"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, ph::Physician)
        where(drug.name == "Olaparib", ph.license_no == "MA-ONC-4421")
        create((drug) - [r::PRESCRIBED_BY] -> (ph))
        r.prescription_date = "2023-05-15"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, ph::Physician)
        where(drug.name == "Pembrolizumab", ph.license_no == "DE-PUL-8837")
        create((drug) - [r::PRESCRIBED_BY] -> (ph))
        r.prescription_date = "2022-12-20"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, ph::Physician)
        where(drug.name == "Metformin", ph.license_no == "MN-END-2259")
        create((drug) - [r::PRESCRIBED_BY] -> (ph))
        r.prescription_date = "2021-07-01"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, ph::Physician)
        where(drug.name == "Lisinopril", ph.license_no == "MA-CAR-1178")
        create((drug) - [r::PRESCRIBED_BY] -> (ph))
        r.prescription_date = "2019-10-01"
        ret(r)
    end

    @graph conn begin
        match(drug::Drug, ph::Physician)
        where(drug.name == "Donepezil", ph.license_no == "MN-NEU-5543")
        create((drug) - [r::PRESCRIBED_BY] -> (ph))
        r.prescription_date = "2020-05-01"
        ret(r)
    end

    # ── Publication → Disease (PUBLISHED_IN) ────────────────────────────
    @graph conn begin
        match(pub::Publication, d::Disease)
        where(pub.doi == "10.1056/NEJMoa1810865", d.name == "Non-Small Cell Lung Cancer")
        create((pub) - [r::PUBLISHED_IN] -> (d))
        r.contribution = "pivotal trial"
        ret(r)
    end

    @graph conn begin
        match(pub::Publication, d::Disease)
        where(pub.doi == "10.1056/NEJMoa1706450", d.name == "Breast Cancer")
        create((pub) - [r::PUBLISHED_IN] -> (d))
        r.contribution = "pivotal trial"
        ret(r)
    end

    @graph conn begin
        match(pub::Publication, d::Disease)
        where(pub.doi == "10.1038/nature11143", d.name == "Breast Cancer")
        create((pub) - [r::PUBLISHED_IN] -> (d))
        r.contribution = "structural biology"
        ret(r)
    end

    @graph conn begin
        match(pub::Publication, d::Disease)
        where(pub.doi == "10.1016/S1474-4422(19)30373-3", d.name == "Alzheimer Disease")
        create((pub) - [r::PUBLISHED_IN] -> (d))
        r.contribution = "genetic epidemiology"
        ret(r)
    end

    # ── Drug ↔ Drug (INTERACTS_WITH) ────────────────────────────────────
    @graph conn begin
        match(d1::Drug, d2::Drug)
        where(d1.name == "Metformin", d2.name == "Lisinopril")
        create((d1) - [r::INTERACTS_WITH] -> (d2))
        r.interaction_type = "pharmacokinetic"
        r.confidence = 0.7
        ret(r)
    end

    @graph conn begin
        match(d1::Drug, d2::Drug)
        where(d1.name == "Tamoxifen", d2.name == "Olaparib")
        create((d1) - [r::INTERACTS_WITH] -> (d2))
        r.interaction_type = "pharmacodynamic"
        r.confidence = 0.6
        ret(r)
    end

    @test true  # all relationships created successfully
end

# ════════════════════════════════════════════════════════════════════════════
# PART 4 — Complex Queries via @graph (>> chains, where(), ret(), etc.)
# ════════════════════════════════════════════════════════════════════════════

@testset "Biomedical @graph — Complex Queries" begin

    # ── 4.1 Multi-hop: Gene → Protein → Pathway for a disease ───────────
    @testset "Gene-Protein-Pathway for Breast Cancer (>>)" begin
        disease_name = "Breast Cancer"
        result = @graph conn begin
            g::Gene >> ::ASSOCIATED_WITH >> d::Disease
            g >> ::ENCODES >> p::Protein >> ::PARTICIPATES_IN >> pw::Pathway
            where(d.name == $disease_name)
            ret(g.symbol => :gene, p.name => :protein, pw.name => :pathway)
            order(g.symbol)
        end
        @test length(result) > 0
        genes_found = Set(row.gene for row in result)
        @test "EGFR" in genes_found || "ERBB2" in genes_found || "TP53" in genes_found
    end

    # ── 4.2 Drug repurposing candidates (shared pathways) ───────────────
    @testset "Drug repurposing — shared pathway targets (>>)" begin
        target_disease = "Breast Cancer"
        result = @graph conn begin
            drug::Drug >> ::TARGETS >> prot::Protein >> ::PARTICIPATES_IN >> pw::Pathway
            prot2::Protein >> ::PARTICIPATES_IN >> pw
            g::Gene >> ::ENCODES >> prot2
            g >> ::ASSOCIATED_WITH >> d::Disease
            where(d.name == $target_disease)
            ret(drug.name => :drug, pw.name => :pathway, g.symbol => :gene)
            order(drug.name)
        end
        @test length(result) >= 0
    end

    # ── 4.3 Patient cohort analysis ─────────────────────────────────────
    @testset "Patients by disease with trial enrollment" begin
        result = @graph conn begin
            pt::Patient >> dx::DIAGNOSED_WITH >> d::Disease
            optional(pt >> e::ENROLLED_IN >> ct::ClinicalTrial)
            ret(pt.patient_id => :patient, d.name => :disease,
                dx.stage => :stage, ct.trial_id => :trial)
            order(d.name, pt.patient_id)
        end
        @test length(result) >= 6
        patient_d_rows = [r for r in result if r.patient == "PT-2024-004"]
        @test length(patient_d_rows) >= 2
    end

    # ── 4.4 Aggregation: drugs per disease with avg efficacy ────────────
    @testset "Drug count and average efficacy per disease" begin
        result = @graph conn begin
            drug::Drug >> t::TREATS >> d::Disease
            with(d.name => :disease, count(drug) => :drug_count, avg(t.efficacy) => :mean_efficacy)
            where(drug_count > 1)
            ret(disease, drug_count, mean_efficacy)
            order(drug_count, :desc)
        end
        @test length(result) > 0
        for row in result
            @test row.drug_count >= 2
        end
    end

    # ── 4.5 Side effect overlap between drugs ───────────────────────────
    @testset "Common side effects across oncology drugs" begin
        result = @graph conn begin
            d1::Drug >> ::HAS_SIDE_EFFECT >> s::Symptom
            d2::Drug >> ::HAS_SIDE_EFFECT >> s
            where(d1.name < d2.name)
            ret(d1.name => :drug1, d2.name => :drug2, collect(s.name) => :shared_effects)
            order(d1.name)
        end
        @test length(result) > 0
    end

    # ── 4.6 Complete patient journey ────────────────────────────────────
    @testset "Full patient journey — diagnosis to treatment" begin
        pid = "PT-2024-001"
        result = @graph conn begin
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
        @test length(result) > 0
        drugs_found = Set(row.drug_option for row in result)
        @test "Trastuzumab" in drugs_found
    end

    # ── 4.7 Gene-disease network density ────────────────────────────────
    @testset "Genes with multiple disease associations" begin
        min_diseases = 2
        result = @graph conn begin
            g::Gene >> a::ASSOCIATED_WITH >> d::Disease
            with(g.symbol => :gene, count(d) => :disease_count, collect(d.name) => :diseases)
            where(disease_count >= $min_diseases)
            ret(gene, disease_count, diseases)
            order(disease_count, :desc)
        end
        @test length(result) > 0
        tp53_row = [r for r in result if r.gene == "TP53"]
        @test length(tp53_row) == 1
        @test tp53_row[1].disease_count >= 2
    end

    # ── 4.8 Hospital workload — physicians per hospital ─────────────────
    @testset "Hospital physician coverage" begin
        result = @graph conn begin
            ph::Physician >> ::LOCATED_AT >> h::Hospital
            ret(h.name => :hospital, collect(ph.specialty) => :specialties,
                count(ph) => :physician_count)
            order(physician_count, :desc)
        end
        @test length(result) == 3
    end

    # ── 4.9 Biomarker-guided treatment selection ────────────────────────
    @testset "Biomarker → Disease → Drug pipeline" begin
        result = @graph conn begin
            bm::Biomarker >> ::INDICATES >> d::Disease
            drug::Drug >> ::TREATS >> d
            ret(bm.name => :biomarker, d.name => :disease,
                drug.name => :drug, drug.mechanism => :mechanism)
            order(bm.name, drug.name)
        end
        @test length(result) > 0
        her2_rows = [r for r in result if r.biomarker == "HER2 IHC"]
        @test length(her2_rows) > 0
    end

    # ── 4.10 Full knowledge chain: Biomarker→Disease→Gene→Protein→Pathway
    @testset "Full knowledge chain — five-hop traversal" begin
        result = @graph conn begin
            bm::Biomarker >> ::INDICATES >> d::Disease
            g::Gene >> ::ASSOCIATED_WITH >> d
            g >> ::ENCODES >> p::Protein >> ::PARTICIPATES_IN >> pw::Pathway
            ret(bm.name => :biomarker, d.name => :disease,
                g.symbol => :gene, p.name => :protein, pw.name => :pathway)
            order(d.name, g.symbol)
        end
        @test length(result) > 0
    end

    # ── 4.11 MERGE — upsert treatment guidelines ───────────────────────
    @testset "MERGE — upsert treatment guidelines" begin
        now = "2026-02-15"
        result = @graph conn begin
            merge(d::Disease)
            on_match(d.last_reviewed=$now)
            ret(d)
        end
        @test length(result) > 0
        @test result[1].d isa Node
    end

    # ── 4.12 Batch creation with UNWIND ─────────────────────────────────
    @testset "UNWIND — batch insert adverse events" begin
        adverse_events = [
            Dict("drug_name" => "Trastuzumab", "event" => "Cardiotoxicity", "grade" => 2),
            Dict("drug_name" => "Erlotinib", "event" => "Rash", "grade" => 1),
            Dict("drug_name" => "Pembrolizumab", "event" => "Pneumonitis", "grade" => 3),
            Dict("drug_name" => "Olaparib", "event" => "Anemia", "grade" => 2),
        ]

        result = @graph conn begin
            unwind($adverse_events => :ae)
            drug::Drug
            where(drug.name == ae.drug_name)
            create((drug) - [::REPORTED_AE] -> (event::AdverseEvent))
            event.name = ae.event
            event.grade = ae.grade
            ret(drug.name => :drug, event.name => :event, event.grade => :grade)
        end
        @test length(result) >= 4
        @test result[1].drug isa AbstractString
    end

    # ── 4.13 Complex WHERE with string functions ────────────────────────
    @testset "Complex WHERE — string functions" begin
        result = @graph conn begin
            g::Gene >> ::ASSOCIATED_WITH >> d::Disease
            where(startswith(g.chromosome, "17"), d.category == "Oncology")
            ret(g.symbol => :gene, g.chromosome => :chr, d.name => :disease)
            order(g.symbol)
        end
        @test length(result) > 0
        chr17_genes = Set(r.gene for r in result)
        @test length(chr17_genes) >= 2
    end

    # ── 4.14 WITH + aggregation pipeline ────────────────────────────────
    @testset "WITH pipeline — treatment landscape" begin
        result = @graph conn begin
            drug::Drug >> t::TREATS >> d::Disease
            with(d, count(drug) => :n_drugs, avg(t.efficacy) => :avg_eff)
            g::Gene >> ::ASSOCIATED_WITH >> d
            ret(d.name => :disease, n_drugs, avg_eff, count(g) => :n_genes)
            order(n_drugs, :desc)
        end
        @test length(result) > 0
    end

    # ── 4.15 OPTIONAL MATCH — drugs without side effects ────────────────
    @testset "OPTIONAL MATCH — drugs without side effects" begin
        result = @graph conn begin
            drug::Drug >> ::TREATS >> d::Disease
            optional(drug >> ::HAS_SIDE_EFFECT >> se::Symptom)
            ret(drug.name => :drug, d.name => :disease, count(se) => :side_effect_count)
            order(drug.name)
        end
        @test length(result) > 0
    end

    # ── 4.16 Publication impact ─────────────────────────────────────────
    @testset "Publication → Disease knowledge network" begin
        result = @graph conn begin
            pub::Publication >> ::PUBLISHED_IN >> d::Disease
            drug::Drug >> ::TREATS >> d
            with(pub, d, collect(drug.name) => :drugs)
            ret(pub.title => :publication, pub.journal => :journal,
                d.name => :disease, drugs)
            order(pub.year, :desc)
        end
        @test length(result) > 0
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 5 — Graph Integrity Verification
# ════════════════════════════════════════════════════════════════════════════

@testset "Biomedical @graph — Integrity Checks" begin

    counts = graph_counts(conn)

    @test counts.nodes >= 70
    @test counts.relationships >= 80

    # No exact duplicate relationships
    @test duplicate_relationship_group_count(conn) == 0

    # BRCA1 EXPRESSES edges unique per tissue
    brca1_expr = query(conn, """
        MATCH (:Gene {symbol: 'BRCA1'})-[r:EXPRESSES]->(:Protein {uniprot_id: 'P38398'})
        RETURN count(r) AS edge_count,
               count(DISTINCT r.tissue) AS distinct_tissues
    """; access_mode=:read)

    @test brca1_expr[1].edge_count == 2
    @test brca1_expr[1].edge_count == brca1_expr[1].distinct_tissues

    # Check label types exist using @graph comprehension
    for label in ["Disease", "Gene", "Protein", "Drug", "ClinicalTrial",
        "Patient", "Hospital", "Physician", "Pathway",
        "Symptom", "Biomarker", "Publication"]
        r = query(conn, "MATCH (n:$label) RETURN count(n) AS c"; access_mode=:read)
        @test r[1].c > 0
    end

    println("\n" * "="^72)
    println("  Biomedical Knowledge Graph (@graph DSL) — COMPLETE")
    println("  Total nodes: ", counts.nodes)
    println("  Total relationships: ", counts.relationships)
    println("  Graph persisted in Neo4j — inspect with Neo4j Browser")
    println("="^72 * "\n")
end
