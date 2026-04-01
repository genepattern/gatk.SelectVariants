#!/bin/bash
# runLocal.sh -- Run gatk.SelectVariants locally in Docker using gpunit test data.
# Uses the same pre-existing broadinstitute/gatk image as the GenePattern module,
# mounting the wrapper script from this directory rather than baking it into the image.
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${MODULE_DIR}/gpunit/data"
RUN_DIR="${MODULE_DIR}/gpunit/local_runs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RUN_DIR}"

IMAGE="broadinstitute/gatk:4.1.4.1"
WRAPPER="${MODULE_DIR}/gatk_selectvariants_wrapper.sh"

echo "=== gatk.SelectVariants local Docker test run ==="
echo "=== Image:   ${IMAGE}"
echo "=== Data:    ${DATA_DIR}"
echo "=== Output:  ${RUN_DIR}"
echo ""

CMD=(docker run --rm
  -v "${DATA_DIR}:/data"
  -v "${RUN_DIR}:/work"
  -v "${WRAPPER}:/usr/local/bin/gatk_selectvariants_wrapper.sh"
  -w /work
  "${IMAGE}"
  bash /usr/local/bin/gatk_selectvariants_wrapper.sh
    --input.vcf           /data/mito_unfiltered.vcf
    --reference           /data/Homo_sapiens_assembly38.mt_only.fasta
    --reference.fai       /data/Homo_sapiens_assembly38.mt_only.fasta.fai
    --reference.dict      /data/Homo_sapiens_assembly38.mt_only.dict
    --select.type.to.include SNP
    --output.vcf.name     mito_snps.vcf
)

echo "=== Running command ==="
echo "${CMD[*]}"
echo ""

"${CMD[@]}"

echo ""
echo "=== Run complete. Output files in: ${RUN_DIR} ==="
ls -lh "${RUN_DIR}/"
