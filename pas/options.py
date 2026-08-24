import argparse
from caches import *

def get_options():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--type",
        "-t",
        type=str,
        choices=caches,
        default="set-assoc"
    )

    parser.add_argument(
        "--assoc",
        "-a",
        type=int,
        help="The associativity of the cache.",
        default=8
    )

    parser.add_argument(
        "--size",
        "-s",
        type=int,
        help="The size of the cache.",
        default=32768
    )
    
    parser.add_argument(
        "--parts",
        "-p",
        type=int,
        help="The number of skews or partitions in the cache.",
        default=4
    )
    
    parser.add_argument(
        "--domains",
        type=int,
        help="The number of domains in the cache.",
        default=16
    )
    
    args = parser.parse_args()
    return args