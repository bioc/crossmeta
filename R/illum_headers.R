# makes headline on line 1 and ILMN_\\d+ on line 2
setup_hline <- function (rawf) {
    hline <- 0

    # count frequency of headline pattern
    count <- c()
    maxl  <- c(0)
    pattern <- 'detection|pval|signal|id'

    for (i in 1:20) {
        # split on tab
        rawfi <- rawf[i]
        rawfi <- unlist(strsplit(rawfi, split = '\t'))
        count <- c(count, sum(grepl(pattern, rawfi, TRUE)))

        if (length(rawfi) > maxl) maxl <- length(rawfi)
    }

    # set headline
    freq <- count / maxl
    if (any(freq > 0.25)) {
        hline <- which.max(freq)
    }

    # get ilmn line
    iline <- grep('ILMN_\\d+', rawf[1:20])[1]
    if (is.na(iline)) iline <- hline + 1
    if (hline == 0)   hline <- iline - 1

    # remove lines before hline and between hline and iline
    int <- setdiff(1:iline, c(hline, iline))
    if (length(int)) rawf <- rawf[-int]
    return(rawf)
}

#' Count numeric columns in raw Illumina data files
#' 
#' Excludes probe ID cols
#'
#' @param elist_paths Paths to raw illumina data files
#'
#' @return Number of numeric columns in \code{elist_paths} excluding probe ID columns.
#' 
ilmn.nnum <- function(elist_paths) {
  nnum <- 0
  for (fpath in elist_paths) {
    # fread first 1000 rows as example
    ex <- data.table::fread(fpath, sep = '\t', skip = 0, header = TRUE, nrows = 1000, fill = TRUE)
    ex <- as.data.frame(ex)
    
    # remove any columns that start with V (autonamed by data.table)
    ex <- remove_autonamed(ex)
    
    isnum   <- unname(sapply(ex, is.numeric))
    isprobe <- unname(sapply(ex, function(col) is.integer(col) & min(col) > 10000))
    isnum   <- isnum & !isprobe
    
    # bug fix for GSE38012 with NAs in ENTREZ_GENE_ID column of ex
    isnum   <- isnum & !is.na(isnum)
    
    # keep tally
    nnum <- nnum + sum(isnum)
  }
  return(nnum)
}

#' Remove columns that are autonamed by data.table
#' 
#' Auto-named columns start with 'V' followed by the column number.
#'
#' @param ex data.frame loaded with \link[data.table]{fread}
#'
#' @return \code{ex} with auto-named columns removed.
#' 
remove_autonamed <- function(ex) {
  cols <- colnames(ex)
  vcol.names <- paste0('V', seq_along(cols))
  is.auto <- cols == vcol.names
  ex[, cols[is.auto]] <- NULL
  return(ex)
}

#' Run prefix on Illumina raw data files
#'
#' @param elist_paths Paths to raw Illumina data files
#'
#' @return Paths to fixed versions of \code{elist_paths}
#' 
prefix_illum_headers <- function(elist_paths) {
  
  fpaths <- c()
  for (path in elist_paths) {
    # fixed path
    fpath <- gsub(".txt", "_fixed.txt", path, fixed = TRUE)
    
    # read raw file
    rawf <- readLines(path)
    
    # make tab separated if currently not
    delim <- reader::get.delim(path, n=50, skip=100)
    if (delim != '\t') rawf <- gsub(delim, '\t', rawf)
    
    # exclude lines starting with hashtag
    exclude <- grepl('^.?#', rawf)
    rawf <- rawf[!exclude]
    
    # remove trailing tabs
    rawf <- gsub('\t*$', '', rawf)
    
    # setup header line
    rawf <- setup_hline(rawf)
    
    # save as will read from
    writeLines(rawf, fpath)
    
    fpaths <- c(fpaths, fpath)
  }
  
  return(fpaths)
}


#' Attempts to fix Illumina raw data header
#' 
#' Reads raw data files and tries to fix them up so that they can be loaded by \link[limma]{read.ilmn}.
#'
#' @param elist_paths Path to Illumina raw data files. Usually contain patterns:
#'   non_normalized.txt, raw.txt, or _supplementary_.txt
#' @param eset ExpressionSet from \link{getGEO}.
#'
#' @return Character vector for \code{annotation} argument to \link[limma]{read.ilmn}. Fixed raw data files
#'   are saved with filename ending in _fixed.txt
#'
fix_illum_headers <- function(elist_paths, eset = NULL) {

    annotation <- c()
    
    # need to run for all so that can get nnum
    fpaths <- prefix_illum_headers(elist_paths)
    
    # number of numeric columns in all Illumina raw data files
    nnum <- ilmn.nnum(fpaths)
    
    for (fpath in fpaths) {

        # read prefixed raw file
        rawf <- readLines(fpath)

        # fread first 1000 rows as example
        ex <- data.table::fread(fpath, sep = '\t', skip = 0, header = TRUE, nrows = 1000, fill = TRUE, )
        ex <- as.data.frame(ex)

        # fix annotation columns ----

        # look for first column with ILMN entries
        # error is limma::read.ilmn if more than one idcol 
        nilmn  <- apply(ex, 2, function(col) sum(grepl('ILMN_', col)))
        idcol  <- which(nilmn > 950)[1]

        # fix if idcol is not ID_REF
        if (length(idcol) && names(idcol) != 'ID_REF') {

            # incase other column named ID_REF
            oldref <- which(names(ex) == 'ID_REF')
            if (length(oldref)) names(ex)[oldref] <- 'OLD_REF'

            names(ex)[idcol] <- 'ID_REF'
            rawf[1] <- paste0(names(ex), collapse = '\t')
        }
        
        # remove any columns that start with V then column number (autonamed by data.table)
        ex <- remove_autonamed(ex)

        # identify other annotation columns
        isnum   <- unname(sapply(ex, is.numeric))
        isprobe <- unname(sapply(ex, function(col) is.integer(col) & min(col) > 10000))
        isnum   <- isnum & !isprobe
        
        # bug fix for GSE38012 with NAs in ENTREZ_GENE_ID column of ex
        isnum   <- isnum & !is.na(isnum)

        annotation <- c(annotation, names(ex)[!isnum])

        # rename Signal and Pvalue identifiers ----
        pcols <- which(grepl('pval|detection', colnames(ex), TRUE) & isnum)
        scols <- which(grepl('signal', colnames(ex), TRUE) & isnum)

        # rename pvalue columns
        if (length(pcols)) {

            # longest common prefix or suffix in pvalue columns
            pcol_prefix <- get_lcstring(colnames(ex)[pcols])
            pcol_sufix  <- get_lcstring(colnames(ex)[pcols], 'suffix')

            if (grepl('pval|detection', pcol_prefix, TRUE)) {
                colnames(ex)[pcols] <- gsub(pcol_prefix, '', colnames(ex)[pcols])
                colnames(ex)[pcols] <- paste0('Detection-', colnames(ex)[pcols])

                rawf[1] <- paste0(colnames(ex), collapse = '\t')

            } else if (grepl('pval|detection', pcol_sufix, TRUE)) {
                colnames(ex)[pcols] <- gsub(pcol_sufix, '', colnames(ex)[pcols])
                colnames(ex)[pcols] <- paste0('Detection-', colnames(ex)[pcols])

                rawf[1] <- paste0(colnames(ex), collapse = '\t')
            }
        }

        # rename signal columns
        if (length(scols)) {

            # longest common prefix or suffix in pvalue columns
            scol_prefix <- get_lcstring(colnames(ex)[scols])
            scol_sufix  <- get_lcstring(colnames(ex)[scols], 'suffix')

            if (grepl('signal', scol_prefix, TRUE)) {
                colnames(ex)[scols] <- gsub(scol_prefix, '', colnames(ex)[scols])
                colnames(ex)[scols] <- paste0('AVG_Signal-', colnames(ex)[scols])

                rawf[1] <- paste0(colnames(ex), collapse = '\t')

            } else if (grepl('signal', scol_sufix, TRUE)) {
                colnames(ex)[scols] <- gsub(scol_sufix, '', colnames(ex)[scols])
                colnames(ex)[scols] <- paste0('AVG_Signal-', colnames(ex)[scols])

                rawf[1] <- paste0(colnames(ex), collapse = '\t')
            }
        }


        # if Pvalue every second column, set Signal to every first ----
        if (!length(pcols))
            pcols <- unname(which(sapply(ex, function(col) ifelse(is.numeric(col), max(col) < 1.01, FALSE))))

        if (length(pcols))
            p2nd <- isTRUE(all.equal(seq(min(pcols), max(pcols), 2), pcols))

        if (length(pcols) && p2nd) {
            # make Signal columns to left of Pvalue columns
            # (if couldn't detect)
            if (!length(scols) || length(scols) != length(pcols))
                scols <- pcols-1

            # use Signal column for sample names
            sample_names <- gsub('AVG_Signal-', '', colnames(ex)[scols])

            colnames(ex)[scols] <- paste0('AVG_Signal-', sample_names)
            colnames(ex)[pcols] <- paste0('Detection-', sample_names)

            rawf[1] <- paste(colnames(ex), collapse = '\t')
        }

        # if num numeric columns is twice num pcols or scols, set unidentified ----
        if (!length(pcols) && length(scols)*2 == sum(isnum)) {
            pcols <- setdiff(which(isnum), scols)
            colnames(ex)[pcols] <- paste0('Detection-', colnames(ex)[pcols])
            rawf[1] <- paste0(colnames(ex), collapse = '\t')
        }

        if (!length(scols) && length(pcols)*2 == sum(isnum)) {
            scols <- setdiff(which(isnum), pcols)
            colnames(ex)[scols] <- paste0('AVG_Signal-', colnames(ex)[scols])
            rawf[1] <- paste0(colnames(ex), collapse = '\t')
        }


        # if num numeric columns (in all elist_paths) is n samples in eset, set Signal to numeric columns ----

        if (!is.null(eset)) {
            nsamp <- ncol(eset)

            if (nnum == nsamp) {
                # add Signal identifier to all numeric columns
                colnames(ex)[isnum] <- gsub('AVG_Signal-', '', colnames(ex)[isnum])
                colnames(ex)[isnum] <- paste0('AVG_Signal-', colnames(ex)[isnum])

                rawf[1] <- paste0(colnames(ex), collapse = '\t')
            }
        }

        writeLines(rawf, fpath)
    }
    # for multiple raw files
    annotation <- unique(annotation)
    if (!length(annotation) || identical(annotation, 'ID_REF')) annotation = c("TargetID", "SYMBOL", "ID_REF")
    return(annotation)
}


get_lcstring <- function(x, type = 'prefix') {
  
  if (type == 'prefix') {
    lcstring <- Biobase::lcPrefix(x)
    
  } else if (type == 'suffix') {
    lcstring  <- Biobase::lcSuffix(x)
  }
  
  # remove e.g. -L. from "-L.Detection Pval"
  # not sure why but ?? seems to give precedence to retaining '.Detection Pval'
  pattern <- '^(.+)??(.?AVG.?Signal.?|.?Detection.?(Pval)?(ue)?.?)(.+)?$'
  lcstring <- gsub(pattern, '\\2', lcstring)
  return(lcstring)
}