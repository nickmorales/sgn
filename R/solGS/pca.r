 #SNOPSIS

 #runs population structure analysis using PCA from SNPRelate, a bioconductor R package

 #AUTHOR
 # Isaak Y Tecle (iyt2@cornell.edu)


options(echo = FALSE)

library(randomForest)
library(data.table)
library(genoDataFilter)
library(tibble)
library(dplyr)
library(stringr)
library(phenoAnalysis)

allArgs <- commandArgs()

outputFile  <- grep("output_files", allArgs, value = TRUE)
outputFiles <- scan(outputFile, what = "character")

inputFile  <- grep("input_files", allArgs, value = TRUE)
inputFiles <- scan(inputFile, what = "character")

scoresFile       <- grep("pca_scores", outputFiles, value = TRUE)
loadingsFile     <- grep("pca_loadings", outputFiles, value = TRUE)
varianceFile     <- grep("pca_variance", outputFiles, value = TRUE)
combinedDataFile <- grep("combined_pca_data_file", outputFiles, value = TRUE)

if (is.null(scoresFile))
{
  stop("Scores output file is missing.")
  q("no", 1, FALSE) 
}

if (is.null(loadingsFile))
{
  stop("Laodings file is missing.")
  q("no", 1, FALSE)
}

genoData         <- c()
genoMetaData     <- c()
filteredGenoFile <- c()
phenoData        <- c()

pcF <- grepl("genotype", inputFiles)
dataType <- ifelse(isTRUE(pcF[1]), 'genotype', 'phenotype')

if (dataType == 'genotype') {
    if (length(inputFiles) > 1 ) {   
        allGenoFiles <- inputFiles
        genoData <- combineGenoData(allGenoFiles)
        
        genoMetaData   <- genoData$trial
        genoData$trial <- NULL
        
    } else {
        genoDataFile <- grep("genotype_data", inputFiles,  value = TRUE)
        genoData     <- fread(genoDataFile,
                              na.strings = c("NA", " ", "--", "-", "."))
        
        genoData     <- unique(genoData, by='V1')
        
        filteredGenoFile <- grep("filtered_genotype_data_",
                                 genoDataFile,
                                 value = TRUE)

        if (!is.null(genoData)) { 
            genoData <- data.frame(genoData)
            genoData <- column_to_rownames(genoData, 'V1')          
        } else {
            genoData <- fread(filteredGenoFile)
        }
    }
} else if (dataType == 'phenotype') {

    metaFile <- grep("meta", inputFiles,  value = TRUE)
    phenoFiles <- grep("phenotype_data", inputFiles,  value = TRUE)

    if (length(phenoFiles) > 1 ) {
        
        phenoData <- combinePhenoData(phenoFiles, metaDataFile = metaFile)
        phenoData <- summarizeTraits(phenoData, groupBy=c('studyDbId', 'germplasmName'))
        
        if (all(is.na(phenoData$locationName))) {        
            phenoData$locationName <- 'location'
        }
        
        phenoData <- na.omit(phenoData)
        genoMetaData <- phenoData$studyDbId
    
        phenoData <- phenoData %>% mutate(germplasmName = paste0(germplasmName, '_', studyDbId))
        dropCols = c('replicate', 'blockNumber', 'locationName', 'studyDbId', 'studyYear')
        phenoData <- phenoData %>% select(-dropCols)
        phenoData <- column_to_rownames(phenoData, var="germplasmName")       
    } else {   
        phenoDataFile <- grep("phenotype_data", inputFiles,  value = TRUE)
  
        phenoData <- cleanAveragePhenotypes(inputFiles, metaFile)       
        phenoData <- na.omit(phenoData)
    }
    
    phenoData <- scale(phenoData, center=TRUE, scale=TRUE)
    phenoData <- round(phenoData, 3)
}


if (is.null(genoData) && is.null(phenoData)) {
  stop("There is no data to run PCA.")
  q("no", 1, FALSE)
} 

genoDataMissing <- c()
if (dataType == 'genotype') {
    if (is.null(filteredGenoFile) == TRUE) {
        ##genoDataFilter::filterGenoData       
        genoData <- filterGenoData(genoData, maf=0.01)
        genoData <- column_to_rownames(genoData, 'rn')

        message("No. of geno missing values, ", sum(is.na(genoData)) )
        if (sum(is.na(genoData)) > 0) {
            genoDataMissing <- c('yes')
            genoData <- na.roughfix(genoData)
        }
    }

    genoData <- data.frame(genoData)
}
## nCores <- detectCores()
## message('no cores: ', nCores)
## if (nCores > 1) {
##   nCores <- (nCores %/% 2)
## } else {
##   nCores <- 1
## }

pcaData <- c()
if (!is.null(genoData)) {
    pcaData <- genoData
} else if(!is.null(phenoData)) {
    pcaData <- phenoData
}

pcsCnt <- ifelse(ncol(pcaData) < 10, ncol(pcaData), 10)
pca    <- prcomp(pcaData, retx=TRUE)
pca    <- summary(pca)

scores   <- data.frame(pca$x)
scores   <- scores[, 1:pcsCnt]
scores   <- round(scores, 3)

if (!is.null(genoMetaData)) {
    scores$trial <- genoMetaData
    scores       <- scores %>% select(trial, everything()) %>% data.frame
} else {
  scores$trial <- 1000
  scores <- scores %>% select(trial, everything()) %>% data.frame
}

scores   <- scores[order(row.names(scores)), ]

variances <- data.frame(pca$importance)
variances <- variances[2, 1:pcsCnt]
variances <- round(variances, 4) * 100
variances <- data.frame(t(variances))

colnames(variances) <- 'variances'

loadings <- data.frame(pca$rotation)
loadings <- loadings[, 1:pcsCnt]
loadings <- round(loadings, 3)

fwrite(scores,
       file      = scoresFile,
       sep       = "\t",
       row.names = TRUE,
       quote     = FALSE,
       )

fwrite(loadings,
       file      = loadingsFile,
       sep       = "\t",
       row.names = TRUE,
       quote     = FALSE,
       )

fwrite(variances,
       file      = varianceFile,
       sep       = "\t",
       row.names = TRUE,
       quote     = FALSE,
       )


if (length(inputFiles) > 1) {
    fwrite(genoData,
       file      = combinedDataFile,
       sep       = "\t",
       row.names = TRUE,
       quote     = FALSE,
       )

}

## if (!is.null(genoDataMissing)) {
## fwrite(genoData,
##        file      = genoDataFile,
##        sep       = "\t",
##        row.names = TRUE,
##        quote     = FALSE,
##        )

## }


q(save = "no", runLast = FALSE)
