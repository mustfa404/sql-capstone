"""Master pipeline executor: runs phase1 -> phase2 -> phase3 in strict order."""
import logging
import time

from scripts import phase1, phase2, phase3

logger = logging.getLogger(__name__)

PHASES = {
    1: ("Business Understanding", phase1),
    2: ("Data Understanding", phase2),
    3: ("Data Preparation", phase3),
}


def run_phase(number):
    """Run a single CRISP-DM phase."""
    if number not in PHASES:
        raise ValueError(f"Unknown phase {number}; choose from {sorted(PHASES)}")
    title, module = PHASES[number]
    logger.info("===== Phase %s: %s =====", number, title)
    started = time.perf_counter()
    module.run()
    logger.info("Phase %s finished in %.1fs", number, time.perf_counter() - started)


def run_all():
    """Run the complete pipeline (phase 1, 2, 3)."""
    started = time.perf_counter()
    for number in sorted(PHASES):
        run_phase(number)
    logger.info("Full pipeline finished in %.1fs", time.perf_counter() - started)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    run_all()
