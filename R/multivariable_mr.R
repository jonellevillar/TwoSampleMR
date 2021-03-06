
#' Extract exposure variables for multivariable MR
#'
#' Requires a list of IDs from \code{available_outcomes()}. For each ID, it extracts instruments. Then, it gets the full list of all instruments and extracts those SNPs for every exposure. Finally, it keeps only the SNPs that are a) independent and b) present in all exposures, and harmonises them to be all on the same strand. 
#'
#' @param id_exposure Array of IDs (e.g. c(299, 300, 302) for HDL, LDL, trigs)
#' @param clump_r2=0.01 Once a full list of
#' @param clump_kb=10000 <what param does>
#' @param access_token Google OAuth2 access token. Used to authenticate level of access to data
#' @param find_proxies Look for proxies? This slows everything down but is more accurate. Default TRUE
#' @param force_server=FALSE Whether to search through pre-clumped dataset or to re-extract and clump directly from the server
#'
#' @export
#' @return data frame in exposure_dat format
mv_extract_exposures <- function(id_exposure, clump_r2=0.001, clump_kb=10000, harmonise_strictness=2, access_token = ieugwasr::check_access_token(), find_proxies=TRUE, force_server=FALSE)
{
	require(reshape2)
	stopifnot(length(id_exposure) > 1)

	# Get best instruments for each exposure
	exposure_dat <- extract_instruments(id_exposure, r2 = clump_r2, kb=clump_kb, access_token = access_token, force_server=force_server)
	temp <- exposure_dat
	temp$id.exposure <- 1
	temp <- clump_data(temp, clump_r2=clump_r2, clump_kb=clump_kb)
	exposure_dat <- subset(exposure_dat, SNP %in% temp$SNP)


	# Get effects of each instrument from each exposure
	d1 <- extract_outcome_data(exposure_dat$SNP, id_exposure, access_token = access_token, proxies=find_proxies)
	stopifnot(length(unique(d1$id)) == length(unique(id_exposure)))
	d1 <- subset(d1, mr_keep.outcome)
	d2 <- subset(d1, id.outcome != id_exposure[1])
	d1 <- convert_outcome_to_exposure(subset(d1, id.outcome == id_exposure[1]))

	# Harmonise against the first id
	d <- harmonise_data(d1, d2, action=harmonise_strictness)

	# Only keep SNPs that are present in all
	tab <- table(d$SNP)
	keepsnps <- names(tab)[tab == length(id_exposure)-1]
	d <- subset(d, SNP %in% keepsnps)
	
	# Reshape exposures
	dh1 <- subset(d, id.outcome == id.outcome[1], select=c(SNP, exposure, id.exposure, effect_allele.exposure, other_allele.exposure, eaf.exposure, beta.exposure, se.exposure, pval.exposure))
	dh2 <- subset(d, select=c(SNP, outcome, id.outcome, effect_allele.outcome, other_allele.outcome, eaf.outcome, beta.outcome, se.outcome, pval.outcome))
	names(dh2) <- gsub("outcome", "exposure", names(dh2))
	dh <- rbind(dh1, dh2)
	return(dh)
}


#' Harmonise exposure and outcome for multivariable MR
#'
#'
#' @param exposure_dat Output from \code{mv_extract_exposures}
#' @param outcome_dat Output from \code{extract_outcome_data(exposure_dat$SNP, id_output)}
#'
#' @export
#' @return List of vectors and matrices required for mv analysis. exposure_beta is a matrix of beta coefficients, rows correspond to SNPs and columns correspond to exposures. exposure_pval is the same as exposure_beta, but for p-values. exposure_se is the same as exposure_beta, but for standard errors. outcome_beta is an array of effects for the outcome, corresponding to the SNPs in exposure_beta. outcome_se and outcome_pval are as in outcome_beta.
mv_harmonise_data <- function(exposure_dat, outcome_dat, harmonise_strictness=2)
{

	stopifnot(all(c("SNP", "id.exposure", "exposure", "effect_allele.exposure", "beta.exposure", "se.exposure", "pval.exposure") %in% names(exposure_dat)))
	nexp <- length(unique(exposure_dat$id.exposure))
	stopifnot(nexp > 1)
	tab <- table(exposure_dat$SNP)
	keepsnp <- names(tab)[tab == nexp]
	exposure_dat <- subset(exposure_dat, SNP %in% keepsnp)


	exposure_mat <- reshape2::dcast(exposure_dat, SNP ~ id.exposure, value.var="beta.exposure")


	# Get outcome data
	dat <- harmonise_data(subset(exposure_dat, id.exposure == exposure_dat$id.exposure[1]), outcome_dat, action=harmonise_strictness)
	dat <- subset(dat, mr_keep)
	dat$SNP <- as.character(dat$SNP)

	exposure_beta <- reshape2::dcast(exposure_dat, SNP ~ id.exposure, value.var="beta.exposure")
	exposure_beta <- subset(exposure_beta, SNP %in% dat$SNP)
	exposure_beta$SNP <- as.character(exposure_beta$SNP)

	exposure_pval <- reshape2::dcast(exposure_dat, SNP ~ id.exposure, value.var="pval.exposure")
	exposure_pval <- subset(exposure_pval, SNP %in% dat$SNP)
	exposure_pval$SNP <- as.character(exposure_pval$SNP)

	exposure_se <- reshape2::dcast(exposure_dat, SNP ~ id.exposure, value.var="se.exposure")
	exposure_se <- subset(exposure_se, SNP %in% dat$SNP)
	exposure_se$SNP <- as.character(exposure_se$SNP)

	index <- match(exposure_beta$SNP, dat$SNP)
	dat <- dat[index, ]
	stopifnot(all(dat$SNP == exposure_beta$SNP))

	exposure_beta <- as.matrix(exposure_beta[,-1])
	exposure_pval <- as.matrix(exposure_pval[,-1])
	exposure_se <- as.matrix(exposure_se[,-1])

	rownames(exposure_beta) <- dat$SNP
	rownames(exposure_pval) <- dat$SNP
	rownames(exposure_se) <- dat$SNP

	outcome_beta <- dat$beta.outcome
	outcome_se <- dat$se.outcome
	outcome_pval <- dat$pval.outcome

	expname <- subset(exposure_dat, !duplicated(id.exposure), select=c(id.exposure, exposure))
	outname <- subset(outcome_dat, !duplicated(id.outcome), select=c(id.outcome, outcome))


	return(list(exposure_beta=exposure_beta, exposure_pval=exposure_pval, exposure_se=exposure_se, outcome_beta=outcome_beta, outcome_pval=outcome_pval, outcome_se=outcome_se, expname=expname, outname=outname))
}


#' Perform basic multivariable MR
#'
#' Performs initial multivariable MR analysis from Burgess et al 2015. For each exposure the outcome is residualised for all the other exposures, then unweighted regression is applied.
#'
#' @param mvdat Output from \code{mv_harmonise_data}
#' @param intercept Should the intercept by estimated (TRUE) or force line through the origin (FALSE, dafault)
#' @param instrument_specific Should the estimate for each exposure be obtained by using all instruments from all exposures (FALSE, default) or by using only the instruments specific to each exposure (TRUE)
#' @param pval_threshold=5e-8 P-value threshold to include instruments
#' @param plots Create plots? FALSE by default
#'
#' @export
#' @return List of results
mv_residual <- function(mvdat, intercept=FALSE, instrument_specific=FALSE, pval_threshold=5e-8, plots=FALSE)
{
	# This is a matrix of 
	beta.outcome <- mvdat$outcome_beta
	beta.exposure <- mvdat$exposure_beta
	pval.exposure <- mvdat$exposure_pval

	nexp <- ncol(beta.exposure)
	effs <- array(1:nexp)
	se <- array(1:nexp)
	pval <- array(1:nexp)
	nsnp <- array(1:nexp)
	marginal_outcome <- matrix(0, nrow(beta.exposure), ncol(beta.exposure))
	p <- list()
	nom <- colnames(beta.exposure)
	nom2 <- mvdat$expname$exposure[match(nom, mvdat$expname$id.exposure)]
	for (i in 1:nexp) {

		# For this exposure, only keep SNPs that meet some p-value threshold
		index <- pval.exposure[,i] < pval_threshold

		# Get outcome effects adjusted for all effects on all other exposures
		if(intercept)
		{
			if(instrument_specific)
			{
				marginal_outcome[index,i] <- lm(beta.outcome[index] ~ beta.exposure[index, -c(i), drop=FALSE])$res
				mod <- summary(lm(marginal_outcome[index,i] ~ beta.exposure[index, i]))
			} else {
				marginal_outcome[,i] <- lm(beta.outcome ~ beta.exposure[, -c(i), drop=FALSE])$res
				mod <- summary(lm(marginal_outcome[,i] ~ beta.exposure[,i]))
			}
		} else {
			if(instrument_specific)
			{
				marginal_outcome[index,i] <- lm(beta.outcome[index] ~ 0 + beta.exposure[index, -c(i), drop=FALSE])$res
				mod <- summary(lm(marginal_outcome[index,i] ~ 0 + beta.exposure[index, i]))
			} else {
				marginal_outcome[,i] <- lm(beta.outcome ~ 0 + beta.exposure[, -c(i), drop=FALSE])$res
				mod <- summary(lm(marginal_outcome[,i] ~ 0 + beta.exposure[,i]))
			}			
		}
		if(sum(index) > (nexp + as.numeric(intercept)))
		{
			effs[i] <- mod$coef[as.numeric(intercept) + 1, 1]
			se[i] <- mod$coef[as.numeric(intercept) + 1, 2]
		} else {
			effs[i] <- NA
			se[i] <- NA
		}
		pval[i] <- 2 * pnorm(abs(effs[i])/se[i], lower.tail = FALSE)
		nsnp[i] <- sum(index)

		# Make scatter plot
		d <- data.frame(outcome=marginal_outcome[,i], exposure=beta.exposure[,i])
		flip <- sign(d$exposure) == -1
		d$outcome[flip] <- d$outcome[flip] * -1
		d$exposure <- abs(d$exposure)
		if(plots)
		{
			p[[i]] <- ggplot2::ggplot(d[index,], ggplot2::aes(x=exposure, y=outcome)) +
			ggplot2::geom_point() +
			ggplot2::geom_abline(intercept=0, slope=effs[i]) +
			# ggplot2::stat_smooth(method="lm") +
			ggplot2::labs(x=paste0("SNP effect on ", nom2[i]), y="Marginal SNP effect on outcome")
		}
	}
	result <- data.frame(id.exposure = nom, id.outcome = mvdat$outname$id.outcome, outcome=mvdat$outname$outcome, nsnp = nsnp, b = effs, se = se, pval = pval, stringsAsFactors = FALSE)
	result <- merge(mvdat$expname, result)
	out <- list(
		result=result,
		marginal_outcome=marginal_outcome
	)

	if(plots) out$plots <- p
	return(out)
}



#' Perform IVW multivariable MR
#'
#' Performs modified multivariable MR analysis. For each exposure the instruments are selected then all exposures for those SNPs are regressed against the outcome together, weighting for the inverse variance of the outcome.
#'
#' @param mvdat Output from \code{mv_harmonise_data}
#' @param intercept Should the intercept by estimated (TRUE) or force line through the origin (FALSE, dafault)
#' @param instrument_specific Should the estimate for each exposure be obtained by using all instruments from all exposures (FALSE, default) or by using only the instruments specific to each exposure (TRUE)
#' @param pval_threshold=5e-8 P-value threshold to include instruments
#' @param plots Create plots? FALSE by default
#'
#' @export
#' @return List of results
mv_multiple <- function(mvdat, intercept=FALSE, instrument_specific=FALSE, pval_threshold=5e-8, plots=FALSE)
{
	# This is a matrix of 
	beta.outcome <- mvdat$outcome_beta
	beta.exposure <- mvdat$exposure_beta
	pval.exposure <- mvdat$exposure_pval
	w <- 1/mvdat$outcome_se^2

	nexp <- ncol(beta.exposure)
	effs <- array(1:nexp)
	se <- array(1:nexp)
	pval <- array(1:nexp)
	nsnp <- array(1:nexp)
	# marginal_outcome <- matrix(0, nrow(beta.exposure), ncol(beta.exposure))
	p <- list()
	nom <- colnames(beta.exposure)
	nom2 <- mvdat$expname$exposure[match(nom, mvdat$expname$id.exposure)]
	for (i in 1:nexp)
	{
		# For this exposure, only keep SNPs that meet some p-value threshold
		index <- pval.exposure[,i] < pval_threshold

		# # Get outcome effects adjusted for all effects on all other exposures
		# marginal_outcome[,i] <- lm(beta.outcome ~ beta.exposure[, -c(i)])$res

		# Get the effect of the exposure on the residuals of the outcome
		if(!intercept)
		{
			if(instrument_specific)
			{
				mod <- summary(lm(beta.outcome[index] ~ 0 + beta.exposure[index, ,drop=FALSE], weights=w[index]))
			} else {
				mod <- summary(lm(beta.outcome ~ 0 + beta.exposure, weights=w))
			}
		} else {
			if(instrument_specific)
			{
				mod <- summary(lm(beta.outcome[index] ~ beta.exposure[index, ,drop=FALSE], weights=w[index]))
			} else {
				mod <- summary(lm(beta.outcome ~ beta.exposure, weights=w))
			}
		}

		if(instrument_specific & sum(index) <= (nexp + as.numeric(intercept)))
		{
			effs[i] <- NA
			se[i] <- NA
		} else {
			effs[i] <- mod$coef[as.numeric(intercept) + i, 1]
			se[i] <- mod$coef[as.numeric(intercept) + i, 2]
		}
		pval[i] <- 2 * pnorm(abs(effs[i])/se[i], lower.tail = FALSE)
		nsnp[i] <- sum(index)

		# Make scatter plot
		d <- data.frame(outcome=beta.outcome, exposure=beta.exposure[,i])
		flip <- sign(d$exposure) == -1
		d$outcome[flip] <- d$outcome[flip] * -1
		d$exposure <- abs(d$exposure)
		if(plots)
		{
			p[[i]] <- ggplot2::ggplot(d[index,], ggplot2::aes(x=exposure, y=outcome)) +
			ggplot2::geom_point() +
			ggplot2::geom_abline(intercept=0, slope=effs[i]) +
			# ggplot2::stat_smooth(method="lm") +
			ggplot2::labs(x=paste0("SNP effect on ", nom2[i]), y="Marginal SNP effect on outcome")
		}
	}
	result <- data.frame(id.exposure = nom, id.outcome = mvdat$outname$id.outcome, outcome=mvdat$outname$outcome, nsnp = nsnp, b = effs, se = se, pval = pval, stringsAsFactors = FALSE)
	result <- merge(mvdat$expname, result)
	out <- list(
		result=result
	)
	if(plots)
		out$plots=p

	return(out)
}

#' Perform basic multivariable MR
#' 
#' Performs initial multivariable MR analysis from Burgess et al 2015. For each exposure the outcome is residualised for all the other exposures, then unweighted regression is applied.
#'
#' @param mvdat Output from \code{mv_harmonise_data}
#' @param pval_threshold=5e-8 P-value threshold to include instruments
#'
#' @export
#' @return List of results
mv_basic <- function(mvdat, pval_threshold=5e-8)
{
	# This is a matrix of 
	beta.outcome <- mvdat$outcome_beta
	beta.exposure <- mvdat$exposure_beta
	pval.exposure <- mvdat$exposure_pval

	nexp <- ncol(beta.exposure)
	effs <- array(1:nexp)
	se <- array(1:nexp)
	pval <- array(1:nexp)
	nsnp <- array(1:nexp)
	marginal_outcome <- matrix(0, nrow(beta.exposure), ncol(beta.exposure))
	p <- list()
	nom <- colnames(beta.exposure)
	nom2 <- mvdat$expname$exposure[match(nom, mvdat$expname$id.exposure)]
	for (i in 1:nexp) {

		# For this exposure, only keep SNPs that meet some p-value threshold
		index <- pval.exposure[,i] < pval_threshold

		# Get outcome effects adjusted for all effects on all other exposures
		marginal_outcome[,i] <- lm(beta.outcome ~ beta.exposure[, -c(i)])$res

		# Get the effect of the exposure on the residuals of the outcome
		mod <- summary(lm(marginal_outcome[index,i] ~ beta.exposure[index, i]))

		effs[i] <- mod$coef[2, 1]
		se[i] <- mod$coef[2, 2]
		pval[i] <- 2 * pnorm(abs(effs[i])/se[i], lower.tail = FALSE)
		nsnp[i] <- sum(index)

		# Make scatter plot
		d <- data.frame(outcome=marginal_outcome[,i], exposure=beta.exposure[,i])
		flip <- sign(d$exposure) == -1
		d$outcome[flip] <- d$outcome[flip] * -1
		d$exposure <- abs(d$exposure)
		p[[i]] <- ggplot2::ggplot(d[index,], ggplot2::aes(x=exposure, y=outcome)) +
		ggplot2::geom_point() +
		ggplot2::geom_abline(intercept=0, slope=effs[i]) +
		# ggplot2::stat_smooth(method="lm") +
		ggplot2::labs(x=paste0("SNP effect on ", nom2[i]), y="Marginal SNP effect on outcome")
	}
	result <- data.frame(id.exposure = nom, id.outcome = mvdat$outname$id.outcome, outcome=mvdat$outname$outcome, nsnp = nsnp, b = effs, se = se, pval = pval, stringsAsFactors = FALSE)
	result <- merge(mvdat$expname, result)

	return(list(result=result, marginal_outcome=marginal_outcome, plots=p))
}



#' Perform IVW multivariable MR
#'
#' Performs modified multivariable MR analysis. For each exposure the instruments are selected then all exposures for those SNPs are regressed against the outcome together, weighting for the inverse variance of the outcome.
#'
#' @param mvdat Output from \code{mv_harmonise_data}
#' @param pval_threshold=5e-8 P-value threshold to include instruments
#'
#' @export
#' @return List of results
mv_ivw <- function(mvdat, pval_threshold=5e-8)
{
	# This is a matrix of 
	beta.outcome <- mvdat$outcome_beta
	beta.exposure <- mvdat$exposure_beta
	pval.exposure <- mvdat$exposure_pval
	w <- 1/mvdat$outcome_se^2

	nexp <- ncol(beta.exposure)
	effs <- array(1:nexp)
	se <- array(1:nexp)
	pval <- array(1:nexp)
	nsnp <- array(1:nexp)
	# marginal_outcome <- matrix(0, nrow(beta.exposure), ncol(beta.exposure))
	p <- list()
	nom <- colnames(beta.exposure)
	nom2 <- mvdat$expname$exposure[match(nom, mvdat$expname$id.exposure)]
	for (i in 1:nexp) {

		# For this exposure, only keep SNPs that meet some p-value threshold
		index <- pval.exposure[,i] < pval_threshold

		# # Get outcome effects adjusted for all effects on all other exposures
		# marginal_outcome[,i] <- lm(beta.outcome ~ beta.exposure[, -c(i)])$res

		# Get the effect of the exposure on the residuals of the outcome
		mod <- summary(lm(beta.outcome[index] ~ 0 + beta.exposure[index, ], weights=w[index]))

		effs[i] <- mod$coef[i, 1]
		se[i] <- mod$coef[i, 2]
		pval[i] <- 2 * pnorm(abs(effs[i])/se[i], lower.tail = FALSE)
		nsnp[i] <- sum(index)

		# Make scatter plot
		d <- data.frame(outcome=beta.outcome, exposure=beta.exposure[,i])
		flip <- sign(d$exposure) == -1
		d$outcome[flip] <- d$outcome[flip] * -1
		d$exposure <- abs(d$exposure)
		p[[i]] <- ggplot2::ggplot(d[index,], ggplot2::aes(x=exposure, y=outcome)) +
		ggplot2::geom_point() +
		ggplot2::geom_abline(intercept=0, slope=effs[i]) +
		# ggplot2::stat_smooth(method="lm") +
		ggplot2::labs(x=paste0("SNP effect on ", nom2[i]), y="Marginal SNP effect on outcome")
	}
	result <- data.frame(id.exposure = nom, id.outcome = mvdat$outname$id.outcome, outcome=mvdat$outname$outcome, nsnp = nsnp, b = effs, se = se, pval = pval, stringsAsFactors = FALSE)
	result <- merge(mvdat$expname, result)

	return(list(result=result, plots=p))
}

#' Apply LASSO feature selection to mvdat object
#'
#' @param mvdat Output from \code{mv_harmonise_data}
#'
#' @export
#' @return data frame of retained features
mv_lasso_feature_selection <- function(mvdat)
{
	message("Performing feature selection")
	b <- glmnet::cv.glmnet(x=mvdat$exposure_beta, y=mvdat$outcome_beta, weight=1/mvdat$outcome_se^2, intercept=0)
	c <- coef(b, s = "lambda.min")
  	i <- !c[,1] == 0
  	d <- dplyr::tibble(exposure=rownames(c)[i], b=c[i,])
	return(d)
}

#' Perform multivariable MR on subset of features
#'
#' Step 1: Select features (by default this is done using LASSO feature selection)
#' Step 2: Subset the mvdat to only retain relevant features and instruments
#' Step 3: Perform MVMR on remaining data
#'
#' @param mvdat Output from \code{mv_harmonise_data}
#' @param features Dataframe of features to retain, must have column with name 'exposure' that has list of exposures tor etain from mvdat. By default = mvdat_lasso_feature_selection(mvdat)
#' @param intercept Should the intercept by estimated (TRUE) or force line through the origin (FALSE, dafault)
#' @param instrument_specific Should the estimate for each exposure be obtained by using all instruments from all exposures (FALSE, default) or by using only the instruments specific to each exposure (TRUE)
#' @param pval_threshold=5e-8 P-value threshold to include instruments
#' @param plots Create plots? FALSE by default
#'
#' @export
#' @return List of results
mv_subset <- function(mvdat, features=mv_lasso_feature_selection(mvdat), intercept=FALSE, instrument_specific=FALSE, pval_threshold=5e-8, plots=FALSE)
{
	# Update mvdat object
	mvdat$exposure_beta <- mvdat$exposure_beta[, features$exposure, drop=FALSE]
	mvdat$exposure_se <- mvdat$exposure_se[, features$exposure, drop=FALSE]
	mvdat$exposure_pval <- mvdat$exposure_pval[, features$exposure, drop=FALSE]

	# Find relevant instruments
	instruments <- apply(mvdat$exposure_pval, 1, function(x) any(x < pval_threshold))
	stopifnot(sum(instruments) > nrow(features))

	mvdat$exposure_beta <- mvdat$exposure_beta[instruments,,drop=FALSE]
	mvdat$exposure_se <- mvdat$exposure_se[instruments,,drop=FALSE]
	mvdat$exposure_pval <- mvdat$exposure_pval[instruments,,drop=FALSE]	
	mvdat$outcome_beta <- mvdat$outcome_beta[instruments]
	mvdat$outcome_se <- mvdat$outcome_se[instruments]
	mvdat$outcome_pval <- mvdat$outcome_pval[instruments]

	mv_multiple(mvdat, intercept=intercept, instrument_specific=instrument_specific, pval_threshold=pval_threshold, plots=plots)
}

