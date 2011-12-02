## adapted from Hadley's decumar: https://github.com/hadley/decumar

## split input document into groups containing chunks and other texts
## (may contain inline R code)
split_file = function(path) {
    lines = readLines(path, warn = FALSE)
    n = length(lines)
    chunk.begin = knit_patterns$get('chunk.begin')
    chunk.end = knit_patterns$get('chunk.end')
    if (is.null(chunk.begin) || is.null(chunk.end)) {
        warning("no patterns found! input not parsed")
        return(str_c(lines, collapse = '\n'))
    }

    set_tikz_opts(lines, chunk.begin, chunk.end)  # prepare for tikz option 'standAlone'

    blks = which(str_detect(lines, chunk.begin))
    ends = which(str_detect(lines, chunk.end))

    if ((n1 <- length(blks)) > (n2 <- length(ends))) {
        stop('chunk not closed at line ', str_c(tail(blks, n1 - n2), collapse = ','),
             call. = FALSE)
    } else if (n1 < n2) {
        lines[tail(ends, n2 - n1)] = ''  # remove these ends
        warning('extra endings ', chunk.end, ' removed')
        ends = head(ends, n1)
    }
    if (n1 && length(n3 <- which(diff(as.vector(t(cbind(blks, ends)))) <= 0)))
        stop('chunk ended too early at line ', ends[ceiling(n3[1] / 2)], call. = FALSE)

    tmp = logical(n)
    tmp[blks] = TRUE; tmp[ends + 1] = TRUE; length(tmp) = n
    groups = unname(split(lines, cumsum(tmp)))

    ## parse 'em all
    lapply(groups, function(g) {
        block = str_detect(g[1], chunk.begin)
        if (block) parse_block(g) else parse_inline(g)
    })
}

## strip the pattern in code
strip_block = function(x) {
    if (!is.null(prefix <- knit_patterns$get('chunk.code')) && (n <- length(x)) > 2) {
        x[-c(1, n)] = str_replace(x[-c(1, n)], prefix, "")
    }
    x
}

## separate params and R code in code chunks
parse_block = function(input) {
    block = strip_block(input)
    n = length(block); chunk.begin = knit_patterns$get('chunk.begin')
    params = if (group_pattern(chunk.begin)) gsub(chunk.begin, '\\1', block[1]) else ''

    structure(list(params = parse_params(params), code = block[-c(1, n)]),
              class = 'block')
}

## parse params from chunk header
parse_params = function(params, label = TRUE) {
    pieces = str_split(str_split(params, ',')[[1]], '=')
    n = sapply(pieces, length)
    ## when global options are empty
    if (length(n) == 1 && length(pieces[[1]]) == 1) {
        if (!label) {
            return(list())
        } else {
            return(list(label = if (is_blank(pieces[[1]]))
                        str_c('unnamed-chunk-', chunk_counter()) else pieces[[1]]))
        }
    }

    if (any(n == 1)) {
        if (label && length(idx <- which(n == 1)) == 1) {
            pieces[[idx]] = c('label', pieces[[idx]])
        } else stop("illegal tags: ", str_c(names(pieces)[idx[-1]], collapse = ', '), "\n",
                    "all options must be of the form 'tag=value' except the chunk label",
                    call. = FALSE)
    } else if (label && !str_detect(params, '\\s*label\\s*=')) {
        pieces[[length(pieces) + 1]] = c('label', str_c('unnamed-chunk-', chunk_counter()))
    }

    values = lapply(pieces, function(x) str_trim(x[2]))
    names(values) = str_trim(tolower(lapply(pieces, `[`, 1)))

    lapply(values, type.convert, as.is = TRUE)
}

print.block = function(x, ...) {
    if (length(params <- x$params) > 0)
        idx = setdiff(names(params), 'label')
        cat(str_c(strwrap(str_c(params$label, ": ", if (length(idx)) {
            str_c(idx, "=", unlist(params[idx]), collapse = ", ")
        } else ''), indent = 2, exdent = 4), collapse = '\n'), "\n")
    if (opts_knit$get('verbose') && length(x$code) && !all(str_detect(x$code, '^\\s*$'))) {
        cat("\n  ", str_pad(" R code chunk ", getOption('width') - 10L, 'both', '~'), "\n")
        cat(str_c('   ', x$code, collapse = '\n'), '\n')
        cat('  ', str_dup('~', getOption('width') - 10L), '\n')
    }
    cat('\n')
}

## extract inline R code fragments (as well as global options)
parse_inline = function(input) {
    input = str_c(input, collapse = '\n') # merge into one line

    locate_inline = function(input, pattern) {
        x = cbind(start = numeric(0), end = numeric(0))
        if (group_pattern(pattern))
            x = str_locate_all(input, pattern)[[1]]
        x
    }

    params = list(); global.options = knit_patterns$get('global.options')
    opts.line = locate_inline(input, global.options)
    if (nrow(opts.line)) {
        last = tail(opts.line, 1)
        opts = str_match(str_sub(input, last[1, 1], last[1, 2]), global.options)[, 2]
        params = parse_params(opts, label = FALSE)
        ## remove texts for global options
        text.line = t(matrix(c(1L, t(opts.line) + c(-1L, 1L), str_length(input)), nrow = 2))
        text.line = text.line[text.line[, 1] <= text.line[, 2], , drop = FALSE]
        input = str_c(str_sub(input, text.line[, 1], text.line[, 2]), collapse = '')
    }
    inline.code = knit_patterns$get('inline.code')
    loc = locate_inline(input, inline.code)

    structure(list(input = input, location = loc, params = params,
                   code = str_match(str_sub(input, loc[, 1], loc[, 2]), inline.code)[, 2]),
              class = 'inline')
}

print.inline = function(x, ...) {
    if (nrow(x$location)) {
        cat('   ')
        if (opts_knit$get('verbose')) {
            cat(str_pad(" inline R code fragments ",
                        getOption('width') - 10L, 'both', '-'), '\n')
            cat(sprintf('    %s:%s %s', x$location[, 1], x$location[, 2], x$code),
                sep = '\n')
            cat('  ', str_dup('-', getOption('width') - 10L), '\n')
        } else cat('inline R code fragments\n')
    } else cat('  ordinary text without R code\n')
    cat('\n')
}

## parse an external R script
parse_external = function(path) {
    lines = readLines(path, warn = FALSE)
    lab = knit_patterns$get('ref.label')
    if (!group_pattern(lab)) return()
    groups = unname(split(lines, cumsum(str_detect(lines, lab))))
    labels = str_trim(str_replace(sapply(groups, `[`, 1), lab, '\\1'))
    code = lapply(groups, strip_external)
    idx = nzchar(labels); code = code[idx]; labels = labels[idx]
    names(code) = labels
    .knitEnv$ext.code = code; .knitEnv$ext.path = path
    code
}

strip_external = function(x) {
    x = x[-1]; if (!length(x)) return(x)
    while(is_blank(x[1])) {
        x = x[-1]; if (!length(x)) return(x)
    }
    while(is_blank(x[(n <- length(x))])) {
        x = x[-n]; if (n < 2) return(x)
    }
    x
}