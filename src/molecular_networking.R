# create molecular networking from pairswise similarity tables

sim_min <- as.numeric(0.6)
max_rows <- 3000

# read input
args <- commandArgs(trailingOnly=TRUE)
if (length(args) < 3) {
  stop("Three arguments must be supplied to create the molecular networking of similarities (MN):\n", 
       " 1 - Path to the output data folder, inside the outs directory of the clustering results folder. The resulting MN edge table will be saved inside the molecular_network dir;\n", 
       " 2 - Minimum cosine score that must occur between a pair of consensus MS/MS spectra in order for an edge to be formed in the molecular network. Lower value will increase the size of the clusters by inducing the clustering of less related MS/MS spectra, higher value will limit to the opposite;\n", 
       " 3 - Maximum number of rows to process at a time.\n",
       call.=FALSE)
} else {
  output_path <- file.path(args[[1]])
  if (!dir.exists(output_path))
  {
    stop("The job output folder '", output_path, 
         "' do not exists. Provide a valid path to where the the job final result is located.")
  }
  output_name <- basename(output_path)
  
  path_sim_table <- file.path(output_path, "molecular_networking", "similarity_tables", 
                              paste0("similarity_table_", output_name, "_clean.csv"))
  if (!file.exists(path_sim_table)) # get not clean data
    path_sim_table <- file.path(output_path, "molecular_networking", "similarity_tables", 
                                paste0("similarity_table_", output_name, ".csv"))
  output_path <- file.path(output_path, "molecular_networking") 
  
  sim_min <- round(as.numeric(args[[2]]), 2)
  max_rows <- as.integer(args[[3]])
}

cat("Loading package readr, dplyr, dlls...\n")
suppressPackageStartupMessages(library(readr))
Rcpp::sourceCpp('src/triangular_matrix_R.cpp')

build_mol_net_sim <- function(output_name, path_sim_table, 
                              output_path, sim_min, max_rows)
{
  create_edges_sim <- function(i, written_rows)
  {
    j <- i + written_rows
    if (j == 1) {
      cat("        |=")
    } else if (j %in% progress_mn) {
      cat("=")
    }
    if (j+1 == n_scans) {
      res_edges <- NULL
      return(res_edges)
    }
    
    if (scans_order[[j+1]] != scans_pairsim[[i,1]])
      stop("An inconsistency was found in the pairwise similary table. The provided pairwise similarity table must have a quadratic dimension NxN, where N is the number os compared spectra.")
    
    # read the scan similarity row
    scans_pairsim_i <- unlist(scans_pairsim[i,(j+2):n_scans], use.names = FALSE)
    
    # get analog scans
    neighbors_sim <-  which_ge(scans_pairsim_i, sim_min, 0) #which(scans_pairsim_i >= sim_min) # which_ge(unlist(scans_pairsim[i,]), sim_min, 0) #
    
    if (length(neighbors_sim) > 0)
    {
      # return the edges
      res_edges <-  data.frame(msclusterID_source = scans_order[[j+1]], 
                               msclusterID_target = scans_order[neighbors_sim + (j+1)], 
                               cosine = scans_pairsim_i[neighbors_sim], 
                               stringsAsFactors = FALSE)
    } else {
      # no edges
      res_edges <- NULL
    }
    
    rm(scans_pairsim_i, neighbors_sim)
    res_edges
  }
  
  if (!file.exists(path_sim_table))
  {
    stop("The pairwise similarity table file '", path_sim_table,
         "' do not exists. Provide a valid path to where it is located.")
  }
  if (!dir.exists(output_path))
  {
    stop("The output folder '", output_path, 
         "' do not exists. Provide a valid path to where the MN should be saved.")
  }
  if (sim_min < 0 || sim_min > 1.0)
  {
    stop("The minimum similarity threshold must be a non negative numeric value less or equal to 1",
         " (x in [0,1.0]). Wrong sim_min value: ", sim_min)
  }
  if (max_rows < 100)
  {
    warning("The max number of spectra (rows) to be processed at a time was too small. ",
            "Setting it to 100.", call. = FALSE)
    max_rows <- 100
  }
  
  # read the scans present in the provided pairwise sim table - first row
  scans_order <- unlist(suppressMessages(readr::read_csv(path_sim_table, n_max = 1, col_names = FALSE)), 
                    use.names = FALSE)
  n_scans <- length(scans_order)
  
  # number maximum of rows to read at a time
  max_rows <- min(n_scans, max_rows)
  
  # keep the single scans that did not have an edge
  single_scans_ann <- single_scans_sim <- scans_order[-1]
  
  # create the edge file for sim mn
  write.table(t(c("msclusterID_source", "msclusterID_target", "cosine")),
              file = file.path(output_path, paste0(output_name,"_molecular_networking_sim_",sub("\\.", "", sim_min),".selfloop")), sep = ",",
              row.names = FALSE, col.names = FALSE)
  
  options(readr.show_progress = FALSE)
  # for each scan pairwise comparisions create the MN nodes and edges
  cat("\n  * Creating the Molecular Networking of Similarities with", n_scans-1, "nodes *\n")
  ti <- Sys.time()
  # add progress
  progress_mn <- unique(trunc(c(seq(from = 2, to = n_scans, 
                                      by = n_scans/min(30, n_scans)), 
                                n_scans)))
  cat("        |", rep("", length(progress_mn)-1), "|\n")
  
  # divide the job in chunks of 10^4 lines
  for (k in seq_len(ceiling(n_scans/max_rows)))
  {
    scans_pairsim <- suppressMessages(readr::read_csv(path_sim_table, skip = (max_rows*(k-1)+1), 
                                               n_max = max_rows, 
                                            col_names = FALSE))
    
    ###############
    # similarity MN
    ###############
    edges_mn <- lapply(seq_len(nrow(scans_pairsim)),
                           create_edges_sim, max_rows*(k-1))
    edges_mn <- dplyr::bind_rows(edges_mn[!sapply(edges_mn, is.null)])
    rm(scans_pairsim)
    
    # remove the scans with a neighbor from the single list
    single_scans_sim <- single_scans_sim[!(single_scans_sim %in% 
                                             (c(edges_mn$msclusterID_source, 
                                                edges_mn$msclusterID_target)))]
    # write the edges for the first k nodes
    readr::write_csv(edges_mn, path = file.path(output_path, 
                                                paste0(output_name,"_molecular_networking_sim_",
                                                       sub("\\.", "", sim_min), ".selfloop")),
                     append = TRUE, col_names = FALSE)
    
    rm(edges_mn)
  }
  # write the single nodes as self loops  for the isolated ones
  edges_mn <- data.frame(msclusterID_source = single_scans_sim,
                         msclusterID_target = single_scans_sim,
                         cosine = rep(1.00, length(single_scans_sim)),
                         stringsAsFactors = FALSE)
  
  readr::write_csv(edges_mn, path = file.path(output_path, 
                                              paste0(output_name,"_molecular_networking_sim_",
                                                     sub("\\.", "", sim_min), ".selfloop")),
                   append = TRUE, col_names = FALSE)
  
  # add the annotations in the similarity table if the mn of annotations is present
  if (file.exists(file.path(output_path, 
                            paste0(output_name,
                                   "_molecular_networking_annotations.selfloop"))))
  {
    edges_mn_sim <- suppressMessages(readr::read_csv(
      file.path(output_path, paste0(output_name,"_molecular_networking_sim_",
                                    sub("\\.", "", sim_min), ".selfloop"))))
    edges_mn_ann <- suppressMessages(readr::read_csv(
      file.path(output_path, paste0(output_name,
                                    "_molecular_networking_annotations.selfloop"))))
    edges_mn_ann <- edges_mn_ann[!is.na(edges_mn_ann$annotation),]
    
    edges_mn_sim$annotation <- apply(edges_mn_sim, 1, function(x, ann_edges)
    {
      match_undirect_edge <- (ann_edges$msclusterID_source == x[[1]] & 
                                  ann_edges$msclusterID_target == x[[2]]) | 
                                 (ann_edges$msclusterID_source == x[[2]] &
                                  ann_edges$msclusterID_target == x[[1]])
      if (any(match_undirect_edge)) {
        paste(unlist(ann_edges[match_undirect_edge, "annotation"]), collapse = ";") 
      } else {
        ""
      }
    }, edges_mn_ann)
    
    readr::write_csv(edges_mn_sim, path = file.path(output_path, 
                                                paste0(output_name,"_molecular_networking_sim_",
                                                       sub("\\.", "", sim_min), ".selfloop")))
  }
  
  cat("|\n")
  tf <- Sys.time()
  cat("    * Done creating the molecular network of similarities in", 
          round(tf-ti, 2), units(tf-ti), "*\n")
  # print(nodes_degree)
} 

build_mol_net_sim(output_name, path_sim_table, output_path, 
                  sim_min, max_rows)
