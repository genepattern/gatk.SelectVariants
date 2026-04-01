#!/bin/bash
set -euo pipefail

# gatk.SelectVariants GenePattern wrapper
# Selects a subset of variants from a VCF file based on variant type,
# sample identity, JEXL filter expressions, and filtering status.
#
# Required GATK arguments: -V (input VCF), -R (reference), -O (output)
# Optional GATK arguments: --select-type-to-include, -select (expression),
#   --exclude-filtered, --exclude-non-variants, --remove-unused-alternates,
#   --keep-original-chr-counts, --sample-name,
#   --arguments_file, --gatk-config-file
#
# Companion files reference.fai and reference.dict are staged alongside
# the reference FASTA so GATK can locate them automatically.
# input.vcf.tbi (if provided) is staged alongside the input VCF.

TOOL_NAME="gatk.SelectVariants"

# ---------------------------------------------------------------------------
# Parameter variables (populated by parse_arguments)
# ---------------------------------------------------------------------------
INPUT_VCF=""
INPUT_VCF_TBI=""
REFERENCE=""
REFERENCE_FAI=""
REFERENCE_DICT=""
OUTPUT_VCF_NAME=""
SELECT_TYPE_TO_INCLUDE=""
SELECT_EXPRESSIONS=""
EXCLUDE_FILTERED=""
EXCLUDE_NON_VARIANTS=""
REMOVE_UNUSED_ALTERNATES=""
KEEP_ORIGINAL_CHR_COUNTS=""
SAMPLE_NAME=""
ARGUMENTS_FILE=""
GATK_CONFIG_FILE=""

# Staged file tracking (filled by stage_inputs; cleared by cleanup)
LOCAL_REFERENCE=""
LOCAL_REFERENCE_FAI=""
LOCAL_REFERENCE_DICT=""
LOCAL_INPUT_VCF=""
LOCAL_INPUT_VCF_TBI=""

# ---------------------------------------------------------------------------
# Cleanup trap -- always runs on EXIT (success or failure)
# ---------------------------------------------------------------------------
cleanup() {
    local f
    for f in \
        "$LOCAL_REFERENCE" \
        "$LOCAL_REFERENCE_FAI" \
        "$LOCAL_REFERENCE_DICT" \
        "$LOCAL_INPUT_VCF" \
        "$LOCAL_INPUT_VCF_TBI"
    do
        if [[ -n "$f" && -f "$f" ]]; then
            rm -f "$f"
        fi
    done
    echo "[INFO] Cleanup complete."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "GenePattern wrapper for GATK SelectVariants"
    echo ""
    echo "Required options:"
    echo "  --input.vcf FILE                      Input VCF (.vcf or .vcf.gz)"
    echo "  --reference FILE                      Reference genome FASTA"
    echo "  --reference.fai FILE                  FASTA index (.fai) companion"
    echo "  --reference.dict FILE                 Sequence dictionary (.dict) companion"
    echo "  --output.vcf.name TEXT                Output VCF filename"
    echo ""
    echo "Optional options:"
    echo "  --input.vcf.tbi FILE                  Tabix index for .vcf.gz input"
    echo "  --select.type.to.include TEXT         Variant type: SNP, INDEL, MIXED, MNP, SYMBOLIC, NO_VARIATION"
    echo "  --select.expressions TEXT             JEXL filter expression (e.g. 'AF > 0.001')"
    echo "  --exclude.filtered true|false         Exclude filtered variants"
    echo "  --exclude.non.variants true|false     Exclude non-variant sites"
    echo "  --remove.unused.alternates true|false Remove unused alternate alleles"
    echo "  --keep.original.chr.counts true|false Preserve original AC/AF/AN annotations"
    echo "  --sample.name TEXT                    Sample name to include"
    echo "  --arguments.file FILE                 GATK arguments file"
    echo "  --gatk.config.file FILE               GATK configuration file"
    echo "  -h, --help                            Show this help and exit"
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_arguments() {
    if [[ $# -eq 0 ]]; then
        echo "[ERROR] No arguments provided."
        usage
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input.vcf)
                INPUT_VCF="$2"
                shift 2
                ;;
            --input.vcf.tbi)
                INPUT_VCF_TBI="$2"
                shift 2
                ;;
            --reference)
                REFERENCE="$2"
                shift 2
                ;;
            --reference.fai)
                REFERENCE_FAI="$2"
                shift 2
                ;;
            --reference.dict)
                REFERENCE_DICT="$2"
                shift 2
                ;;
            --output.vcf.name)
                OUTPUT_VCF_NAME="$2"
                shift 2
                ;;
            --select.type.to.include)
                SELECT_TYPE_TO_INCLUDE="$2"
                shift 2
                ;;
            --select.expressions)
                SELECT_EXPRESSIONS="$2"
                shift 2
                ;;
            --exclude.filtered)
                EXCLUDE_FILTERED="$2"
                shift 2
                ;;
            --exclude.non.variants)
                EXCLUDE_NON_VARIANTS="$2"
                shift 2
                ;;
            --remove.unused.alternates)
                REMOVE_UNUSED_ALTERNATES="$2"
                shift 2
                ;;
            --keep.original.chr.counts)
                KEEP_ORIGINAL_CHR_COUNTS="$2"
                shift 2
                ;;
            --sample.name)
                SAMPLE_NAME="$2"
                shift 2
                ;;
            --arguments.file)
                ARGUMENTS_FILE="$2"
                shift 2
                ;;
            --gatk.config.file)
                GATK_CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "[ERROR] Unknown option: $1"
                usage
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
validate_inputs() {
    local errors=0

    if [[ -z "$INPUT_VCF" ]]; then
        echo "[ERROR] --input.vcf is required."
        errors=$((errors+1))
    elif [[ ! -f "$INPUT_VCF" ]]; then
        echo "[ERROR] Input VCF not found: $INPUT_VCF"
        errors=$((errors+1))
    fi

    if [[ -n "$INPUT_VCF_TBI" && ! -f "$INPUT_VCF_TBI" ]]; then
        echo "[ERROR] Input VCF tabix index not found: $INPUT_VCF_TBI"
        errors=$((errors+1))
    fi

    if [[ -z "$REFERENCE" ]]; then
        echo "[ERROR] --reference is required."
        errors=$((errors+1))
    elif [[ ! -f "$REFERENCE" ]]; then
        echo "[ERROR] Reference FASTA not found: $REFERENCE"
        errors=$((errors+1))
    fi

    if [[ -z "$REFERENCE_FAI" ]]; then
        echo "[ERROR] --reference.fai is required."
        errors=$((errors+1))
    elif [[ ! -f "$REFERENCE_FAI" ]]; then
        echo "[ERROR] Reference FASTA index not found: $REFERENCE_FAI"
        errors=$((errors+1))
    fi

    if [[ -z "$REFERENCE_DICT" ]]; then
        echo "[ERROR] --reference.dict is required."
        errors=$((errors+1))
    elif [[ ! -f "$REFERENCE_DICT" ]]; then
        echo "[ERROR] Reference sequence dictionary not found: $REFERENCE_DICT"
        errors=$((errors+1))
    fi

    if [[ -z "$OUTPUT_VCF_NAME" ]]; then
        echo "[ERROR] --output.vcf.name is required."
        errors=$((errors+1))
    fi

    if [[ -n "$ARGUMENTS_FILE" && ! -f "$ARGUMENTS_FILE" ]]; then
        echo "[ERROR] Arguments file not found: $ARGUMENTS_FILE"
        errors=$((errors+1))
    fi

    if [[ -n "$GATK_CONFIG_FILE" && ! -f "$GATK_CONFIG_FILE" ]]; then
        echo "[ERROR] GATK config file not found: $GATK_CONFIG_FILE"
        errors=$((errors+1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        echo "[ERROR] $errors validation error(s) found. Exiting."
        exit 1
    fi

    echo "[INFO] Input validation passed."
}

# ---------------------------------------------------------------------------
# Stage companion files
#
# GATK requires the reference FASTA, its .fai index, and its .dict sequence
# dictionary to all reside in the same directory with consistent names.
# GenePattern uploads each file to a separate job directory, so we must
# copy them into the working directory with the correct naming scheme:
#
#   <basename>.fasta      (reference FASTA)
#   <basename>.fasta.fai  (FASTA index)
#   <basename>.dict       (sequence dictionary; GATK strips last extension)
#
# Similarly, if the input VCF is bgzip-compressed and a .tbi index is
# provided, the index must reside alongside the VCF with the name <vcf>.tbi.
# ---------------------------------------------------------------------------
stage_inputs() {
    local ref_basename
    ref_basename="$(basename "$REFERENCE")"

    # Stage reference FASTA
    LOCAL_REFERENCE="$(pwd)/${ref_basename}"
    if [[ "$REFERENCE" != "$LOCAL_REFERENCE" ]]; then
        echo "[INFO] Staging reference FASTA: ${ref_basename}"
        cp "$REFERENCE" "$LOCAL_REFERENCE"
    fi

    # Stage reference FASTA index as <ref>.fai
    LOCAL_REFERENCE_FAI="${LOCAL_REFERENCE}.fai"
    echo "[INFO] Staging reference FASTA index: ${ref_basename}.fai"
    cp "$REFERENCE_FAI" "$LOCAL_REFERENCE_FAI"

    # Stage reference sequence dictionary as <ref-no-last-ext>.dict
    # GATK derives the dict path by replacing the last extension with .dict,
    # e.g. ref.fasta -> ref.dict, ref.fa -> ref.dict
    local ref_no_ext
    ref_no_ext="${LOCAL_REFERENCE%.*}"
    LOCAL_REFERENCE_DICT="${ref_no_ext}.dict"
    echo "[INFO] Staging reference sequence dictionary: $(basename "$LOCAL_REFERENCE_DICT")"
    cp "$REFERENCE_DICT" "$LOCAL_REFERENCE_DICT"

    # Stage input VCF tabix index alongside VCF (if provided)
    if [[ -n "$INPUT_VCF_TBI" ]]; then
        local vcf_basename
        vcf_basename="$(basename "$INPUT_VCF")"
        LOCAL_INPUT_VCF="$(pwd)/${vcf_basename}"
        LOCAL_INPUT_VCF_TBI="${LOCAL_INPUT_VCF}.tbi"
        echo "[INFO] Staging input VCF: ${vcf_basename}"
        cp "$INPUT_VCF" "$LOCAL_INPUT_VCF"
        echo "[INFO] Staging input VCF tabix index: ${vcf_basename}.tbi"
        cp "$INPUT_VCF_TBI" "$LOCAL_INPUT_VCF_TBI"
        # Update INPUT_VCF to point to staged copy
        INPUT_VCF="$LOCAL_INPUT_VCF"
    fi

    echo "[INFO] All companion files staged successfully."
}

# ---------------------------------------------------------------------------
# Execute GATK SelectVariants
# ---------------------------------------------------------------------------
run_tool() {
    local -a cmd=(gatk SelectVariants)

    # Required arguments
    cmd+=(-V "$INPUT_VCF")
    cmd+=(-R "$LOCAL_REFERENCE")
    cmd+=(-O "$OUTPUT_VCF_NAME")

    # Optional: variant type selection
    if [[ -n "$SELECT_TYPE_TO_INCLUDE" ]]; then
        cmd+=(--select-type-to-include "$SELECT_TYPE_TO_INCLUDE")
    fi

    # Optional: JEXL filter expression
    if [[ -n "$SELECT_EXPRESSIONS" ]]; then
        cmd+=(-select "$SELECT_EXPRESSIONS")
    fi

    # Optional: boolean flags (pass flag only when value is "true")
    if [[ "$EXCLUDE_FILTERED" == "true" ]]; then
        cmd+=(--exclude-filtered)
    fi

    if [[ "$EXCLUDE_NON_VARIANTS" == "true" ]]; then
        cmd+=(--exclude-non-variants)
    fi

    if [[ "$REMOVE_UNUSED_ALTERNATES" == "true" ]]; then
        cmd+=(--remove-unused-alternates)
    fi

    if [[ "$KEEP_ORIGINAL_CHR_COUNTS" == "true" ]]; then
        cmd+=(--keep-original-chr-counts)
    fi

    # Optional: sample selection
    if [[ -n "$SAMPLE_NAME" ]]; then
        cmd+=(--sample-name "$SAMPLE_NAME")
    fi

    # Optional: GATK arguments file
    if [[ -n "$ARGUMENTS_FILE" ]]; then
        cmd+=(--arguments_file "$ARGUMENTS_FILE")
    fi

    # Optional: GATK config file
    if [[ -n "$GATK_CONFIG_FILE" ]]; then
        cmd+=(--gatk-config-file "$GATK_CONFIG_FILE")
    fi

    echo "[INFO] Executing: ${cmd[*]}"
    echo "-------------------------------------------------------------------"

    "${cmd[@]}"
    local exit_code=$?

    echo "-------------------------------------------------------------------"
    if [[ "$exit_code" -ne 0 ]]; then
        echo "[ERROR] gatk SelectVariants failed with exit code ${exit_code}."
        exit "${exit_code}"
    fi

    echo "[INFO] gatk SelectVariants completed successfully."
    echo "[INFO] Output VCF written to: ${OUTPUT_VCF_NAME}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "[INFO] === ${TOOL_NAME} wrapper starting ==="
    echo "[INFO] Working directory: $(pwd)"

    parse_arguments "$@"
    validate_inputs
    stage_inputs
    run_tool

    echo "[INFO] === ${TOOL_NAME} wrapper finished successfully ==="
}

main "$@"
