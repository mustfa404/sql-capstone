"""Interactive CLI for the Olist Feature Store pipeline.

Usage:
    python main.py --phase 1|2|3     run a single CRISP-DM phase
    python main.py --all             run the complete pipeline
    python main.py                   open the interactive menu
"""
import argparse
import logging
import sys

import etl
from config import close_pool

MENU = """
==============================================
  DEPI SQL Capstone - Olist Feature Store
==============================================
  1) Phase 1 - Business Understanding
  2) Phase 2 - Data Understanding (EDA + audit)
  3) Phase 3 - Data Preparation (Feature Store)
  A) Run the complete pipeline
  Q) Quit
"""


def build_parser():
    parser = argparse.ArgumentParser(
        description="Run the SQL-only CRISP-DM pipeline on the Olist database.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--phase", type=int, choices=sorted(etl.PHASES),
                       help="run one phase (1, 2 or 3)")
    group.add_argument("--all", action="store_true", help="run the full pipeline")
    return parser


def interactive_menu():
    while True:
        print(MENU)
        choice = input("Select an option: ").strip().lower()
        if choice in ("q", "quit", "exit"):
            return
        try:
            if choice == "a":
                etl.run_all()
            elif choice in ("1", "2", "3"):
                etl.run_phase(int(choice))
            else:
                print("Invalid option.")
        except Exception as error:  # keep the menu alive after a failure
            logging.getLogger(__name__).error("Run failed: %s", error)


def main(argv=None):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args = build_parser().parse_args(argv)
    try:
        if args.all:
            etl.run_all()
        elif args.phase:
            etl.run_phase(args.phase)
        else:
            interactive_menu()
    except Exception as error:
        logging.getLogger(__name__).error("Pipeline failed: %s", error)
        return 1
    finally:
        close_pool()
    return 0


if __name__ == "__main__":
    sys.exit(main())
