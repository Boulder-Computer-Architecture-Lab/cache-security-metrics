def latexify(fig_width=None, fig_height=None, columns=1, pub="ieee"):
    """Set up matplotlib's RC params for LaTeX plotting.
    Call this before plotting a figure.

    Parameters
    ----------
    fig_width : float, optional, inches
    fig_height : float,  optional, inches
    columns : {1, 2}
    pub: {ieee, acm}
    """

    # code adapted from https://nipunbatra.github.io/blog/posts/2014-06-02-latexify.html

    assert(columns in [1,2])

    if fig_width is None:
        if pub == "ieee":
            fig_width = 3.39 if columns==1 else 6.9 # width in inches
        elif pub == "acm":
            fig_width = 3.44+0.25 if columns==1 else 7.0 # width in inches
        else: 
            raise ValueError("Invalid publication type selected")
    if fig_height is None:
        from math import sqrt
        golden_mean = (sqrt(5)-1.0)/2.0    # Aesthetic ratio
        fig_height = fig_width*golden_mean # height in inches

    MAX_HEIGHT_INCHES = 8.0
    if fig_height > MAX_HEIGHT_INCHES:
        print("WARNING: fig_height too large:" + fig_height + 
              "so will reduce to" + MAX_HEIGHT_INCHES + "inches.")
        fig_height = MAX_HEIGHT_INCHES

    params = {'axes.labelsize': 8, # fontsize for x and y labels (was 10)
              'axes.titlesize': 8,
              'font.size': 8, # was 10
              'legend.fontsize': 7, # was 10
              'xtick.labelsize': 6,
              'ytick.labelsize': 6,
              'figure.figsize': [fig_width,fig_height],
    }
    import matplotlib
    matplotlib.rcParams.update(params)
    
policy_colors = {
    "LRU": "#377eb8",
    "Rand.": "#ff7f00",
    "Tree-PLRU": "#4daf4a",
    "BRRIP": "#a65628",
    "BIP": "#984ea3",
    "FIFO": "#f781bf",
    "Round Robin": "#dede00",
    # "": "#999999"
}

arch_colors = {
    "Set Assoc.": "#377eb8",
    "Fully Assoc.": "#ff7f00",
    "Skewed Assoc.": "#4daf4a",
    "ScatterCache": "#a65628",
    "SassCache": "#984ea3",
    "MIRAGE": "#f781bf",
    "Way Part.": "#dede00",
    # "": "#999999"
}