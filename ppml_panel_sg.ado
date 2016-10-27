program define ppml_panel_sg, eclass

*! PPML (Panel) Structural Gravity Estimation, by Tom Zylkin
*! Department of Economics, National University of Singapore
*! Version 1.06, October, 2016

// requires: reghdfe (if "ols" option used), hdfe

// future:  faster setup of country and year ids, use hdfe to speed up s.e.s

// v1.06  - fixed selectindex() backwards compatibility

// v1.05  - added check for existence and check to make sure user-provided IDs uniquely describe data.

// v1.04: - switched to IRLS, made year optional

// v1.03: - fixed display of #obs, loglikelihood 

// v1.02: - updated collinearity warning to address cases where standard errors are computed to be missing.
//		  - also fixed "variable trade not found" bug.

// v1.01: - fixed 3 typos and addressed bug with industry-by-pair time trends


tempvar exclude X_ij Y_w y_i e_j D tt phi fta_effect OMR IMR ///
				ind_id yr_id exp_id imp_id S M panel_id ///
				X_ij_hat temp time lhs exp_time imp_time
tempname beta v1 n_iter N_obs N_dropped center which id_flag resid_ vers

scalar `vers' = c(version)

version 11
syntax varlist [if] [in],      ///
   EXporter(varname)           /// 
   IMporter(varname)           /// 
   [                           ///
    Year(varname numeric)      /// 
	INDustry(varname)          ///                          
    guessD(varname numeric)    /// These are useful for nested loops, bootstraps, etc.
	guessO(varname numeric)    /// Defaults: D = O = I = 1; TT = 0.
	guessI(varname numeric)    ///
	guessS(varname numeric)    ///
	guessM(varname numeric)    ///
	guessTT(varname numeric)   ///
	guessB(string)             ///
    genD(name)                 ///
	genTT(name)                ///
    genO(name)                 ///
    genI(name)                 ///
	genS(name)                 ///
	genM(name)                 ///
	NOsterr                    /// Do not compute standard errors
	RObust					   /// Options for robust SEs and clustered SEs
	CLUSter_id(name)           ///
	NOPAIR                     /// These options will change the fixed effects structure. "Nopair" = no pair fixed effects
	SYMmetric                  /// Symmetric pair fixed effects (ignored if nopair)
	TREND					   /// use pair-specific linear time trends (ignored if nopair)
	OLSguess                   /// use reghfe to guess betas upfront
	OFFset(name)			   /// a user-specified offset, for if, e.g., you wish to impose constraints on coefficients
	VERBose(int 0)  		   /// 
	TOLerance(real 1e-12)      ///
	MAXiter(int 10000)         ///
	]						 

** Ex: ppml_panel_sg trade fta1 fta2 ..., exp(exp_id) imp(imp_id) y(year_id) ind(industry_id)  
**     guessO(<init OMR>) guessO(<init IMR>) guessD(<init D_ij's>) guessB(<init betas>)
**     genD(<output Dij's>) genO(<output OMRs>) genI(<output IMRs>) genS(ex by yr FEs) genM(im by yr FEs) 

	
/** 0.  parse syntax, create temp vars  **/
tokenize `varlist'
local trade `1'
macro shift
local policyvars `*'
unab policyvars: `*'

if "`industry'" == "" {
	tempvar industry
	gen `industry' = 1
}
else {
	local dash_ind = "-`industry'"
}

if "`year'" == "" {
	if "`nopair'" == "" {
		di in red "Error: Year ID required if -nopair- option not specified"
		exit 111
	}
	else
	{
		tempvar year
		gen `year' =1
	}
}
else {
	local dash_year = "-`year'"
}
					   
local nvars :  word count `policyvars'
*di `nvars'

local rest = "`policyvars'"
forvalues n = 1(1)`nvars' {
	gettoken policyvar_`n' rest: rest
}


/** I. Initialization: flags missing values, checks user inputs for errors, and sets up group IDs, sets initial values for OMR, IMR, D, beta **/
di "Initializing..."

* exclusion catcher
qui gen `exclude' = missing(`trade')

qui sum `trade'
if `r(min)' < 0 {
	di as error "Error: Dependent variable cannot contain negative values"
	exit 111
}

qui forvalues n = 1(1)`nvars' {
	qui replace `exclude' = 1 if missing(`policyvar_`n'')
}

qui marksample touse
qui replace `touse' = 0 if `exclude' 
*marks those specified by [if] or [in] as 1, zero otherwise

if "`offset'" == "" {	//user-defined offset to be passed as an option to sg_ppml_iter algorithm.
	tempvar offset
	cap gen `offset' = 0 if `touse'  
}
else {
	qui replace `touse' = 0 if missing(`offset')   
}

qui gen `X_ij' = `trade' * (1-`exclude') * (`touse') 

// set up IDs 
qui egen `ind_id' = group(`industry') if `touse'
qui egen `yr_id'  = group(`year')     if `touse'
qui egen `exp_id' = group(`exporter') if `touse'
qui egen `imp_id' = group(`importer') if `touse'

qui sum year if `touse'
qui gen     `time' = `year' - `r(min)' if `touse'
qui replace `time' = 0 if "`trend'" == ""

local id_flag = 0
local check_ids = "`exp_id' `imp_id' `ind_id' `yr_id'"							// Check to make sure each obs. is uniquely ID'd by a single 
mata: id_check("`check_ids'",  "`touse'")										// origin, destination, industry, and time						
if `id_flag' != 0 {
	di in red "Error: the set of origin, destination, industry, and time IDs do not uniquely describe the data"
	di in red "If this is not a mistake, try collapsing the data first using collapse (sum)" 
	exit 111
}

mata: country_ids("`exporter'", "`importer'", "`exp_id'", "`imp_id'", "`vers'","`touse'")  //creates unique country IDs, for cases where the set of exporters is not the 
																				           //same as the set of importers
																			  
																				  
// II. Set up fixed effects structure and check for collinearity and possible non-existence of estimates
di "Checking for possible non-existence issues..."
qui egen `exp_time' = group(`yr_id' `ind_id' `exp_id') if `touse'
qui egen `imp_time' = group(`yr_id' `ind_id' `exp_id') if `touse' 
if "`nopair'" != "" {
	scalar `which' = 2
	if "`symmetric'" != "" {
		di in red "Option -symmetric- ignored, since -nopair- enabled"
	}
	if "`trend'" != "" {
		di in red "Option -trend' ignored, since -nopair- enabled"
	}
	qui gen `panel_id' = 1 if `touse'
	qui hdfe `policyvars' if `X_ij'>0, absorb(`exp_time' `imp_time') gen(`resid_')
}
else if "`symmetric'" != "" {
	tempvar pair_id asym_id
	gen `pair_id' = `exporter' + `importer'
	qui replace `pair_id' = `importer' + `exporter' if (`importer' < `exporter')
	qui egen `asym_id' = group(`industry' `exporter' `importer') if `touse'
	qui egen `panel_id' = group(`industry' `pair_id') if `touse'
	if "`trend'" != "" {
		scalar `which' = 4
		qui hdfe `policyvars' if `X_ij'>0, absorb(`exp_time' `imp_time' `panel_id'##c.`time') gen(`resid_')
	}
	else {
		scalar `which' = 1
		qui hdfe `policyvars' if `X_ij'>0, absorb(`exp_time' `imp_time' `panel_id') gen(`resid_')
	}
}
else {
	qui egen `panel_id' = group(`industry' `exporter' `importer') if `touse'
	if "`trend'" != "" {
		scalar `which' = 3
		qui hdfe `policyvars' if `X_ij'>0, absorb(`exp_time' `imp_time' `panel_id'##c.`time') gen(`resid_')
	}
	else {
		scalar `which' = 0
		qui hdfe `policyvars' if `X_ij'>0, absorb(`exp_time' `imp_time' `panel_id') gen(`resid_')
	}
}

//EnsureExist borrows concepts from "RemoveCollinear" by Sergio Correia, originally from -reghdfe-
EnsureExist if `touse', dep(`X_ij') indep(`policyvars') off(`offset') resid(`resid_')
local policyvars `r(okvars)'
local nvars :  word count `policyvars'
local rest = "`policyvars'"
if "`policyvars'" == "" {
	di
	di in red "Error: all main covariates appear to be collinear with the implied set of fixed effects"
	exit 111
}

forvalues n = 1(1)`nvars' {
	gettoken policyvar_`n' rest: rest
}

qui sum `X_ij'
scalar `center' = `r(mean)'
qui replace `X_ij' = `X_ij' / `center' 	//otherwise, the algorithm for computing s.e.s will be sensitive to the scale of the dep. var.

cap gen `Y_w' = .
cap gen `y_i' = .
cap gen `e_j' = .

// The default is that initial `trade' is "frictionless": D=1, ln_phi = 0 ==> IMR = OMR = 1
// The option "olsguess" uses -reghdfe- to initialize betas based on OLS.
if "`olsguess'"!="" {
	tempvar ln_LHS
	qui gen `ln_LHS' = ln(`X_ij') - `offset'
	qui reghdfe `ln_LHS' `policyvars' if `touse', absorb(`exp_time' `imp_time' `panel_id' )
	qui gen `OMR' = 1 if `touse'
	qui gen `IMR' = 1 if `touse'
	qui gen `D'   = 1 if `touse'
	qui gen `tt'  = 0 if `touse' 
	matrix `beta' = J(1, `nvars',0)
	forvalues n = 1(1)`nvars' {
		matrix `beta'[1, `n'] = _b[`policyvar_`n'']
	}
	matrix colnames `beta' = `policyvars'
}
else {
	//else: either use user-specified guesses
	//or: default guess is "frictionless trade: D=1, ln_phi = 0 ==> IMR = OMR = 1
	qui gen `D'   = 1 if `touse'
	qui gen `tt'  = 0 if `touse'
	qui gen `OMR' = 1 if `touse'
	qui gen `IMR' = 1 if `touse'
	if `which' != 2 {
		qui cap replace `D'  = `guessD'  if "`guessD'"  != "" & `touse'
		if (`which' == 3 | `which' == 4) {
			qui cap replace `tt' = `guessTT' if "`guessTT'" != "" & `touse'
		}
	}
	if "`guessO'" != "" {
		qui cap replace `OMR' =  `guessO' if `touse'
	}
	else if "`guessS'" != "" {
		qui cap replace `OMR' = -`guessS' if `touse' // use negative sign to flag as S, not OMR
	}
	if "`guessI'" != "" {
		qui cap replace `IMR' =  `guessI' if `touse'
	}
	else if "`guessM'" != "" {
		qui cap replace `IMR' = -`guessM' if `touse' // use negative sign to flag as M, not IMR
	}
	
	matrix `beta' = J(1, `nvars',0)
	if "`guessB'" != "" {
		local nguesses = min(`nvars',colsof(`guessB')) 
		qui forvalues n = 1(1)`nguesses' {
			cap matrix `beta'[1, `n'] = `guessB'[1,`n']  * (rowsof(`guessB') != .) 
		}
	}
	matrix colnames `beta' = `policyvars'
}


/** III. Iterate on fixed effects using structural gravity and compute Poisson estimates **/
di "Iterating..."
local mata_varlist_iter = "`ind_id' `yr_id' `exp_id' `imp_id' `X_ij' `D' `OMR' `IMR' `tt' `time' `offset'"  //"offset" is the user-specified offset

// compute beta iteratively:
mata: sg_ppml_iter("`policyvars'", "`mata_varlist_iter'", "`beta'", ///
                     "`Y_w'", "`y_i'", "`e_j'", "`which'", ///
					 "`n_iter'", "`N_obs'", "`N_dropped'", "`tolerance'", "`maxiter'", "`verbose'", /// 
					 "`vers'", "`touse'" )  
				 
qui gen `temp' = log((`y_i' * `e_j' * `Y_w') * (`D' / (`OMR' * `IMR')))+(`tt'*`time')+`offset'+log(`center')

matrix colnames `beta' = `policyvars'
qui gen `lhs' = `X_ij' * `center'
qui poisson `lhs' `policyvars' if `touse', offset(`temp') from(`beta') noconst	 // computes e() statistics		 
qui drop `temp' `lhs'
	
matrix colnames `beta' = `policyvars'
matrix rownames `beta' = coeff						 
estimates table, keep(`policyvars')			    //note that the constant is absorbed by `temp'
di "iterations: " `n_iter'
di "tolerance: "   `tolerance'					
					  
if `n_iter' == `maxiter' {
	di in red "Max number of iterations reached before estimates converged. Consider adjusting the maxiter() option"
	di
}
		
		
/** IV. Compute standard errors (if option enabled) and set up for posting. **/
if "`nosterr'"=="" {
	di as text "Computing standard errors"
	if "`cluster_id'" != "" {
		local display_ses = "Clustered standard errors, clustered by `cluster_id' (user-specified)"
	}
	else if "`robust'" != ""{
		local display_ses = "Robust standard errors"
	}
	else if `which'==2 {
		local display_ses = "Robust standard errors (default)"
	}
	else {
		local display_ses = "Clustered standard errors, clustered by `exporter'-`importer'`dash_ind' (default)"
	}
	
	* update "phi" one last time
	qui gen `fta_effect' = 0
	forvalues n = 1(1)`nvars' {
		matrix `beta'[1, `n'] = _b[`policyvar_`n'']
		qui replace `fta_effect' = `fta_effect' + `beta'[1, `n']  * `policyvar_`n''
	}
	qui gen `phi' = `D' * exp(`tt'*`time') * exp(`fta_effect') * exp(`offset')
	qui replace `phi' = 0 if missing(`phi') | `exclude' | !`touse'
	
	local ll=e(ll)
	local ll0=e(ll_0)
	
	
	*** 1. fit X_ij directly using structural gravity
	qui gen `X_ij_hat' = (`y_i' * `e_j' * `Y_w') * (`phi' / (`OMR' * `IMR'))
	qui gen `temp'=sqrt(`X_ij_hat')
	
	
	*** 2. loop over policy vars and "expurgate" fixed effects from each one.
	cap drop _s_*
	cap drop _r_*
	foreach var of varlist `policyvars' {
		di
		di "calculating s.e. of `var'"
		
		// "expurgate" the FEs from each policyvar:
		cap gen _res = .
		local se_mata_varlist = "`ind_id' `yr_id' `exp_id' `imp_id' `X_ij_hat' `time'"
		mata: expurgate_fes("`var'", "`se_mata_varlist'", "`which'", "`touse'")       // returns "_res"
		rename _res _r_`var'
		qui replace `touse' = 0 if missing(_r_`var') 
		
		// What you are getting out of this is the residual associated with each policy var after netting out the FEs via linear regression.
		// You multiply by each residual by the square root of the conditional mean because this is the weight that is implicitly
		// used by the PPML estimator.
		}
	
	
	*** 3. Regress the original dep var on resulting weighted residuals of the policy vars after "expurgating" the influence of the fixed effects.
	qui _regress `X_ij' _r_* if `touse', nocons      

	// The SEs from this regression are the SEs of the betas as though you had performed
    // a Poisson regression with the fixed effects included.
	// This is an application of the Frisch-Waugh-Lovell theorem. See: Figueiredo, Guimaeraes, & Woodward JUE 2015

	
	*** 4. Adjust standard errors for clustering using _robust. Default is clustered SEs, clustered by country-pair.
	local s2=e(rmse)*e(rmse)
	matrix `v1'=e(V)/`s2'
	local N=e(N)
	
	qui replace `temp'=(`X_ij'-`temp'*`temp')/`temp'                          // multiple use of "temp" may be confusing. "temp" here is sqrt(Xij_hat), which is then used to weight residuals
	if ("`cluster_id'" != "") { 
		_robust `temp' if `touse', v(`v1') cluster(`cluster_id')              
	}
	else if "`robust'"!="" {
		_robust `temp' if `touse', v(`v1')
	}
	else if `which'==2 {
		_robust `temp' if `touse', v(`v1')
	}
	else if `which'==1 {
		_robust `temp' if `touse', v(`v1') cluster(`asym_id')
	}
	else {
		_robust `temp' if `touse', v(`v1') cluster(`panel_id')
	}
	
	*** 5. Post estimation results to Stata
	ereturn clear	
	matrix colnames `beta' = `policyvars'
	matrix colnames `beta' = `trade':
	
	matrix rownames `v1' = `policyvars' 
	matrix rownames `v1' = `trade':
	matrix colnames `v1' = `policyvars'
	matrix colnames `v1' = `trade':
	
	//qui sum(`X_ij')
	//local N = r(N)
	ereturn post `beta' `v1', depname(`trade') obs(`N') 

	ereturn scalar ll=`ll'
	ereturn scalar ll_0=`ll0'
	ereturn local cmdline "ppml_panel_sg `0'"
	ereturn local cmd "ppml_panel_sg"
	ereturn local crittype "log likelihood"
	
	cap drop _s_*
	cap drop _r_*  //make these temp vars
}
else {
	di "You have opted not to compute standard errors."
	ereturn clear
	local N=`N_obs'	
	
	//qui sum(`X_ij')
	//local N = r(N)
	eret post `beta', depname(`trade') obs(`N') 
}

// store fixed effects in memory if requested by user
cap drop `genO'
cap drop `genI'
cap drop `genD'
cap drop `genTT'
cap drop `genS'
cap drop `genM'
cap gen `genS' = `y_i' / `OMR'
cap gen `genM' = `e_j' / `IMR'
cap rename `OMR' `genO'
cap rename `IMR' `genI'
cap rename `D'   `genD'
cap rename `tt'  `genTT'

ereturn local cmdline "ppml_panel_sg `0'"
ereturn local cmd "ppml_panel_sg"


// V. Display final regression table and notes
Display

if (`which' == 0 | `which' == 3){
	local pair = "`exporter'-`importer'`dash_ind'"
	di "Fixed Effects included: `exporter'`dash_ind'`dash_year', `importer'`dash_ind'`dash_year', `pair'" 
	if `which' == 3 {
		di "Also includes `pair' time trends"
	}
} 
else if (`which' == 1 | `which' == 4){
	local pair = "`exporter'-`importer'`dash_ind'"
	di "Fixed Effects included: `exporter'`dash_ind'`dash_year', `importer'`dash_ind'`dash_year', `pair' (symmetric)"
	if `which' == 4 {
		di "Also includes (symmetric) `pair' time trends"
	}
}
else if  (`which' == 2) {
	di "Fixed Effects included: `exporter'`dash_ind'`dash_year', `importer'`dash_ind'`dash_year'"
}

if "`nosterr'"=="" {
	di "`display_ses'"
	if (`N_dropped' > 0) {
		local `N_dropped' = `N_dropped'
		di "``N_dropped'' obs. dropped because they belong to groups with all zeros or missing values"
	} 
	di 
	foreach var of varlist `policyvars' {
		if (abs(_b[`var']) / _se[`var'] < .001) | (abs(_b[`var']) / _se[`var'] == .) {
			di in red "`var' appears to be collinear with your set of fixed effects"
			di as text
		}
	}
}
else {
	if (`N_dropped' > 0) {
		local `N_dropped' = `N_dropped'
		di "``N_dropped'' obs. dropped because they belong to groups with all zeros or missing values"
	} 
	di
}
end


/***************************************************************************************/
/*   ENSUREEXIST (adapted  from "RemoveCollinear", by Sergio Correia. see: -reghdfe-) */
/***************************************************************************************/

// -  In general, a covariate "x" should be dropped if, after netting out FEs and the other covariates,
//    there is no residual variation in x within the subsample where lhs > 0.
// -  Also serves as generalized check for collinearity of covariates
// -  Requires using -hdfe- first to partial out FEs from each covariate
// -  Reference: Santos Silva & Tenreyro EL 2010 "On the Existence of MLE Estimates for Poisson Regression" 

*EnsureExist if `touse', dep(`X_ij') indep(`policyvars') off(`offset') resid(`resid_')
program define EnsureExist, rclass
	syntax [if] [in], 			///
	DEPvar(varname numeric) 	///
	INDEPvars(varlist numeric)	///
	OFFset_weight(string)		///
	RESIDuals(string)					
		
	qui marksample touse
	qui _rmcoll `offset_weight' `residuals'* if `touse' & `depvar'>0, forcedrop   // check simple collinearity across `policyvars'
	local okvars = r(varlist)
	if ("`okvars'"==".") local okvars
	local df_m : list sizeof okvars
	
	foreach var of local indepvars {
		local resid_var = "`residuals'`var'"
		local ok1 : list resid_var in okvars
		qui sum `residuals'`var'
		local ok2 = (`r(sd)'>1e-9)												  // residuals are net of FEs; ~0 residual variation implies
		local ok  = (`ok1'&`ok2')												  // collinearity with one or more of the FEs.
		local prefix = cond(`ok', "", "o.")
		local label : char `var'[name]
		if (!`ok') di in red "note: `var' omitted because of collinearity over lhs>0 (creates possible existence issue)"
		local varlist `varlist' `prefix'`var'
		if (`ok') local okvarlist `okvarlist' `var'
	}

	mata: st_local("vars", strtrim(stritrim( "`varlist'" )) )
	mata: st_local("okvars", strtrim(stritrim( "`okvarlist'" )) )
	return local vars "`vars'"
	return local okvars "`okvars'"
	return scalar df_m = `df_m'
end


/*************************************************************************/
/* DISPLAY (adopted from "Display", by Paulo Guimaraes. see: -poi2hdfe-) */
/*************************************************************************/
program define Display
_coef_table_header, title( ******* PPML Panel Structural Gravity Estimation ********** )
_coef_table, level(95)
end


					/*** mata code starts here ***/
					
/*************************************************************/
/* CHECK_ID (checks whether ID vars uniquely describe data)  */
/*************************************************************/

// Sometimes users may make a mistake in providing duplicate observations for the same trade flow.
// This will generate a error letting them know. If this is not done by accident,
// an equivalent specification can be performed by collapsing the data first.

mata:
void id_check(string scalar idvars,| string scalar touse)
{
	
	st_view(id_vars,.,tokens(idvars), touse)
	uniq_ids = uniqrows(id_vars)
	if (rows(id_vars) != rows(uniq_ids)) {
		st_local("id_flag", "1")
	}	
}
					
/*******************************************************************/
/* COUNTRY_IDS (sets up unique numerical exporter and importer IDs) */
/*******************************************************************/
					
// This code only comes into play if the set of exporters differs from the set of
// importers.

mata:
void country_ids(string scalar exp_name, string scalar imp_name, string scalar exp_id_var, 
                string scalar imp_id_var, string scalar vers,| string scalar touse)
{
	EXP_NAMES = st_sdata(.,tokens(exp_name), touse)
	IMP_NAMES = st_sdata(.,tokens(imp_name), touse)
	
	st_view(exp_id,.,tokens(exp_id_var), touse)
	st_view(imp_id,.,tokens(imp_id_var), touse)
	
	vers = st_numscalar(tokens(vers))
	
	exp_uniq = uniqrows(EXP_NAMES)
	imp_uniq = uniqrows(IMP_NAMES)
	
	NN_ex = rows(exp_uniq)
	NN_im = rows(imp_uniq)
	NN_c  = min((NN_ex, NN_im))
	
	exp_id_uniq = (1..NN_ex)'
	imp_id_uniq = (1..NN_im)'

	//Constructing country ids requires tracking countries which only appear as 
	//exporters, but not as importers, and vice versa.
	for (c=1; c<=NN_c-1; c++) {
		if (select(exp_uniq,exp_id_uniq:==c) != select(imp_uniq,imp_id_uniq:==c)) {  
			if (select(exp_uniq,exp_id_uniq:==c) < select(imp_uniq,imp_id_uniq:==c)) {
				imp_id_uniq[selectidx(imp_id_uniq:>=c,vers), 1]=imp_id_uniq[selectidx13(imp_id_uniq:>=c,vers), 1] :+1
				imp_id[selectidx(imp_id :>= c,vers),.] = imp_id[selectidx(imp_id :>= c,vers),.] :+ 1
				NN_im = NN_im + 1
			} 
		   else {
				exp_id_uniq[selectidx(exp_id_uniq:>=c,vers), 1]=exp_id_uniq[selectidx(exp_id_uniq:>=c,vers), 1] :+1
				exp_id[selectidx(exp_id :>= c,vers),1] = exp_id[selectidx(exp_id :>= c,vers),1] :+1
				NN_ex = NN_ex + 1
		   }
		NN_c  = min((NN_ex, NN_im))
		}
	}
}
end

/***************************************************/
/* SG_PPML_ITER (computes PPML estimates for beta) */
/***************************************************/

// This algorithm works by iterating on the system of multilateral resistances in each period, as well as the 
// pair fixed effects and time trend terms which apply across periods, computing a new estimate for
// beta each time through the loop, until betas converge.

mata:
void sg_ppml_iter(string scalar pvars, string scalar mata_varlist_iter, string scalar b, 
				  string scalar Y_w, string scalar y_i, string scalar e_j, string scalar branch, 
				  string scalar n_iter, string scalar N_obs, string scalar N_dropped, string scalar tolerance,
				  string scalar maxiter, string scalar verbose,string scalar vers,| string scalar touse)
{
	real matrix M, pv, X, phi, sumXhat, sumX
	real scalar NN_i, NN_y, NN_n
	real colvector check, P, Pi, y, e, Yw, Pi0, P0, Pi1, P1, D, tt
	
	which = st_numscalar(branch)   // governs which specification to be used (e.g. symmetric vs. asymmetric pair FEs, time trends vs. not, etc)
	
	beta = st_matrix(b)'           // guesses for betas (if specified)
	
	st_view(pv, ., tokens(pvars),touse)
	st_view(M, ., tokens(mata_varlist_iter),touse)
	
	ind_id = M[.,1]   // industry id, year id, exporter and importer ids.
	yr_id  = M[.,2]   
	exp_id = M[.,3]   
	imp_id = M[.,4]   
	
	lhs = M[.,5]      // dependent variable  
		
	NN_i  = max(ind_id)   // total #s of included industries, years, and countries, for use in loops
	NN_y  = max(yr_id)
	NN_n = max((max(exp_id), max(imp_id)))
	
	tol  = strtoreal(tolerance)
	max  = strtoreal(maxiter)
	verb = strtoreal(verbose)
	
	vers = st_numscalar(tokens(vers))
	
	//"X_index" used for passing (unsorted) data to and from (sorted) matrix form.
 	X_index = ( (yr_id:-1) :* NN_i :* NN_n^2 :+ (ind_id:-1) * NN_n^2 :+ (exp_id:-1):* NN_n :+ imp_id)
	
	BIG_N = NN_y*NN_i*NN_n*NN_n
	
	X=D=tt=timevar=user_offset = J(BIG_N,1,0) 	//Note: imposing phi=X=0 is consistent with treating an observation as missing.
		
	X[X_index,1]       = M[.,5] // M[.,5] is trade
	D[X_index,1]       = M[.,6] // M[.,6] is "D"
	tt[X_index,1]      = M[.,9]  // M[.,9] is the set of linear trend coefficients (if trend specified)
	timevar[X_index,1] = M[.,10] // time intervals for use with trends
	
	user_offset[X_index,1] = M[.,11] // user-specified offset, for constraints, etc.
	
	X = colshape(X,NN_n)  // matricizes X as a (sorted) (NN_t * NN_i * NN_n) x (NN_n) matrix
	
	//set up initial, sorted MR terms 
	Pi0 = P0 = P1 = Pi1 =  J(NN_i * NN_y * NN_n, 1, 0)
	P_index1        = (yr_id:-1) :* NN_i :* NN_n :+  (ind_id:-1) :* NN_n :+ imp_id
	Pi_index1       = (yr_id:-1) :* NN_i :* NN_n :+  (ind_id:-1) :* NN_n :+ exp_id
	P_index2        = uniqrows(P_index1)
	Pi_index2       = uniqrows(Pi_index1)
	Pi0[Pi_index2,1] = Pi1[Pi_index2,1] = uniqrows( (Pi_index1, M[.,7]) )[.,2]
	P0[P_index2,1]   = P1[P_index2,1]   = uniqrows( (P_index1, M[.,8]) )[.,2] 

	// simple time vector, with one entry per year, sorted from first to last
	time = uniqrows(timevar)
	
	//set up matrices for output and expenditure shares (y and e), sum of trade over time (sumX)
	y = e = Yw =  J(NN_i * NN_y * NN_n, 1, 0)
	
	if (which == 2) {
		sumX   = J(NN_i * NN_n , NN_n, 1)   //which = 2: no pair fixed effects 
	}
	else {
		sumX   = J(NN_i * NN_n , NN_n, 0)
	}
	if (which == 3 | which == 4) {
		Xtrend = countX = J(NN_i * NN_n , NN_n, 0)	//which = 3 or 4: include time trends
	}
	else {
		Xtrend = countX = J(NN_i * NN_n , NN_n, 1)
	}
	
	// construct Y, E, and Yw, as well as sum of X over time.
	for (t=1; t<=NN_y; t++) {
		for (i=1; i <= NN_i; i++) {
			long_index = ((t-1) * NN_i * NN_n + (i-1)*NN_n + 1, 1 \ (t-1) * NN_i* NN_n + (i-1)*NN_n + NN_n, 1)
			wide_index = ((t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n)

			Yw[|long_index|] = J(NN_n, 1, 1) # sum(X[|wide_index|])
			y[|long_index|] = rowsum(X[|wide_index |]) :/ Yw[|long_index|]
			e[|long_index|] = rowsum(X[|wide_index|]') :/ Yw[|long_index|]	
						
			//sum actual trade values within pairs over time
			//also sum actual trade * t over within pairs over time (for time trends) 
			if (which == 0 | which == 3) {
				sumX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				sumX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				X[|wide_index|]
			}
			else if (which == 1 | which == 4) {      //which = 1 or 4: pair fixed effects are symmetric
				sumX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				sumX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				X[|wide_index|]+
				X[|wide_index|]'
			}
			if (which == 3) {						//which = 3 or 4: include linear time trends
				Xtrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				Xtrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				time[t]*X[|wide_index|]
					
				countX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				countX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				(X[|wide_index|] :> 0)
			}
			if (which == 4) {
				Xtrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				Xtrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				time[t]*X[|wide_index|]+
				time[t]*X[|wide_index|]'
					
				countX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				countX[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				(X[|wide_index|]+X[|wide_index|]' :> 0)
			}
		}
	}
	
	D = D :* colshape( J(NN_y,1,1)#(editmissing(sumX:!=0,0)) ,1)
	
	if (which == 3 | which == 4){
		free_trend = colshape( J(NN_y,1,1)#editmissing(countX :>= 2,0) ,1)		// time trends cannot be ID'd for pairs that do not trade at least twice
		tt = tt :* free_trend
	}
	
	if (min(Pi0)<0) {
		Pi0 = Pi1 = -y:/Pi0  // I set things up so Pi0 < 0 implies user specified "guessS" option, rather than "guessO".
	} 
	if (min(P0)<0) {
		P0  = P1 = -e:/P0    // Likewise for P0 < 0 if user specified "guessM" rather than "guessI".
	} 
	
	YE_Yw  = (y[Pi_index1,.] :* e[P_index1,.] :* Yw[Pi_index1,.])   // = (Y_i * E_j / Y_w), sorted to match the data	(which need not be sorted)
	
	offset =  log((YE_Yw) :/ (Pi1[Pi_index1,.] :* P1[P_index1,.]) :* D[X_index,.] ) + (timevar[X_index,.]:* tt[X_index,.]) + user_offset[X_index,.]
	
	// set up iteration loop
	last_change = change1 = 1
	store_iters = J(rows(beta), rows(beta)+2,.)
	accel_iter1  = accel_iter2 = iter1 = hits = 0 
	even_iter = 1
	if (which == 3 | which == 4) { 
		accel_interval = 250
	}
	else if (which == 2) {
		accel_interval = 50
	}
	else {
		accel_interval = 100
	}
	do {
		phi = J(BIG_N,1,0)
		
		phi[X_index,.] = D[X_index,.] :* exp(timevar[X_index,.]:* tt[X_index,.]) :* exp(pv*beta) :* exp(user_offset[X_index,.])  // "phi" can be thought of as "t^(1-sigma)" from Anderson and van Wincoop (2003) 
		
		phi = colshape(phi,NN_n)
		
		Pi0 = Pi1
		P0  = P1
		if (which == 2) {
			sumXhat = J(NN_i * NN_n , NN_n, 1)
		}
		else {
			sumXhat = J(NN_i * NN_n , NN_n, 0)
		}
		if (which == 3 | which == 4) {
			Xhattrend = J(NN_i * NN_n , NN_n, 0)
			Xhattrend2 = J(NN_i * NN_n , NN_n, 0)
		}
		else {
			Xhattrend = J(NN_i * NN_n , NN_n, 1)
			Xhattrend2 = J(NN_i * NN_n , NN_n, 1)
		}
		for (t=1; t<=NN_y; t++) {
			for (i=1; i<=NN_i; i++) {
				long_index = ((t-1) * NN_i * NN_n + (i-1)*NN_n + 1, 1 \ (t-1) * NN_i* NN_n + (i-1)*NN_n + NN_n, 1)
				wide_index = ((t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n)
			
				// iterate P0 -> P1 , Pi0 -> Pi1, using P = sum(y*phi/Pi); Pi = sum(e*phi/P)
				P1[|long_index|]  = cross(phi[|wide_index|],  (y[|long_index|] :/ Pi0[|long_index|]))
				Pi1[|long_index|] = cross(phi[|wide_index|]', (e[|long_index |] :/ P1[|long_index|]))
				
				// I normalize MRs by imposing them to be the same magnitude.
				adj = sqrt(sum(Pi1[|long_index|]) :/ sum(P1[|long_index|]))	 
				Pi1[|long_index|] = Pi1[|long_index|] :/ adj
				P1[|long_index|]  = P1[|long_index|]  :* adj
				
				// Sum fitted trade values ("Xhat") over time, using structural gravity: Xhat = (Y*E/Yw) *(phi/(P*Pi)) 
				Xhat = editmissing(
					phi[|wide_index|] :*
					y[|long_index|]  :*
					e[|long_index|]' :*
					Yw[|long_index|] :/
					Pi1[|long_index|] :/
					(P1[|long_index|]'# J(NN_n,1,1)),0)
			
				if (which == 0 | which == 3) {
					sumXhat[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
					sumXhat[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] + Xhat
				}

				else if (which == 1 | which == 4) {	//which = 1: symmetric pair fixed effects
					sumXhat[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
					sumXhat[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] + Xhat + Xhat'
				}
		
				// For each ij time trend coeff, the Poisson FOC implies: sum_t{t*X_ij}=sum_t{t*X_ij_hat} 
				if (which == 3) {
					Xhattrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
					Xhattrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
					time[t]*Xhat
					
					Xhattrend2[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] =   // the sum_t{t^2*X_ij_hat} term comes from the Taylor Series approx of the FOC (used below)
					Xhattrend2[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
					time[t]^2*Xhat
				}	
				if (which == 4) {
					Xhattrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
					Xhattrend[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
					time[t]*Xhat + time[t]*Xhat' 
					
					Xhattrend2[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
					Xhattrend2[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
					time[t]^2*Xhat + time[t]^2*Xhat' 
				}
			}
		}
		
		// update pair fixed effect (D) and time trends (tt)
		if (which == 0 | which == 1){
			D  = D  :*  colshape( J(NN_y,1,1)#(editmissing(sumX :/ sumXhat,0)) ,1)
			offset =  log((YE_Yw) :/ (Pi1[Pi_index1,.] :* P1[P_index1,.]) :* D[X_index,.]) + user_offset[X_index,.]
		}
		if (which == 3 | which == 4){
			D   = D  :*  colshape( J(NN_y,1,1)#(editmissing(sumX :/ sumXhat,0)) ,1) 
			dtt = colshape( J(NN_y,1,1)#(editmissing( (Xtrend-Xhattrend)  :/ Xhattrend2,0)) ,1) :* free_trend   // this comes from 1st-order Taylor Series approx. around dtt = 0
			tt  = tt +   min((iter1/50,.99))*dtt
			offset =  log((YE_Yw) :/ (Pi1[Pi_index1,.] :* P1[P_index1,.]) :* D[X_index,.]) +(timevar[X_index,.]:* tt[X_index,.]) + user_offset[X_index,.]
		}
		if (which == 2) {
			offset =  log((YE_Yw) :/ (Pi1[Pi_index1,.] :* P1[P_index1,.])) + user_offset[X_index,.]
		}
		
		if (max(exp(timevar:*tt)) >= 1000) {
			temp = max(exp(timevar:*tt))  
			temp = (ln(100)-ln(temp)):/max(timevar)
			tt   = (tt :+ temp) //:* free_trend
			P1   = P1  :* sqrt(exp(temp:* (time#J(NN_n*NN_i,1,1)) ))
			Pi1  = Pi1 :* sqrt(exp(temp:* (time#J(NN_n*NN_i,1,1)) )) 
		}
		if (max(D) >= 1000) {
			temp = max(D)
			D   = D  :*  (100 / temp)
			P1  = P1 :*  sqrt(100 / temp)
			Pi1 = Pi1 :* sqrt(100 / temp) 
		}

		//simple Newton-Raphson PPML estimation loop. see: http://cameron.econ.ucdavis.edu/stata/cameronwcsug2008.pdf 
		// Iteratively re-weighted least squares
		
		change2 = 1
		iter2   = 0
		if (which == 3 | which == 4){
			even_iter = (mod(iter1,4)==0)
		}
		beta_old1=beta
		
		notmiss = selectidx(offset :!= .,vers) // ensures loop will handle missing values without blowing up.
		
		//IRLS loop: 
		eta  = pv[notmiss,.]*beta 
		mu   = exp(eta + offset[notmiss,.])
		z    = eta + ((lhs[notmiss,.]-mu) :/ mu) 
		XWX  = cross( pv[notmiss,.], mu, pv[notmiss,.])
		XWz  = cross( pv[notmiss,.], mu, z)
		beta = invsym(XWX)*XWz
		// beta = invsym(pv[notmiss,.]'diag(mu)*pv[notmiss,.])*pv[notmiss,.]'diag(mu)'z
		
		/*  // newton-raphson loop (old)
		do {
			mu        = exp(pv[notmiss,.]*beta + offset[notmiss,.])
			grad      = (pv[notmiss,.])'(lhs[notmiss,.]-mu)                     // k x 1 gradient vector
			hes       = makesymmetric( (pv[notmiss,.] :* mu)' pv[notmiss,.])
			beta_old2 = beta
			beta      = beta_old2 + cholinv(hes)*(grad)                         // for future: add an irls option
			change2   = (beta_old2 - beta)'(beta_old2-beta) / (beta' beta)
			iter2     = iter2+1
		} while (change2 > 1e-16 & iter2 < 25)
		*/
		
		//This uses a Steffenson acceleration technique to accelerate guesses after a certain # of iterations
		//Reference: http://link.springer.com/article/10.1007%2FBF01385782
		accel_iter2 = accel_iter2+1
		if ((accel_iter2 > accel_interval | change1 < tol*5000) & even_iter ){  
			if (change1 <= last_change) {
				accel_iter1 = accel_iter1 +1
				store_iters[.,accel_iter1] = beta
				if (accel_iter1 == rows(beta)+2) {
					if (verb != 0) {
						printf("acceleration\n")
					}
					step1  = store_iters[|.,2 \.,rows(beta)+1|] - store_iters[|.,1 \.,rows(beta)|]
					step2  = store_iters[|.,3 \.,rows(beta)+2|] - store_iters[|.,2 \.,rows(beta)+1|]	
					Lambda = step2 * luinv(step1)
					beta_old1 = store_iters[.,1]
					beta   = store_iters[.,1] + luinv(I(rows(beta)) - Lambda) * step1[.,1]
					
					// protect against overshooting the solution. 
					if (change1 < tol*5000) {
						if (max(abs(beta - store_iters[.,rows(beta)+2])) > .01) {
								beta = store_iters[.,rows(beta)+2]
						}
						else if (change1 < tol*1000) {
							if (max(abs(beta - store_iters[.,rows(beta)+2])) > .005) {
								beta = store_iters[.,rows(beta)+2]
							}
							else if (change1 < tol*100) { 
								if (max(abs(beta - store_iters[.,rows(beta)+2])) > .0025) {
									beta = store_iters[.,rows(beta)+2]
								}
								else if (change1 < 10*tol) {
									if (max(abs(beta - store_iters[.,rows(beta)+2])) > .001) {
										beta = store_iters[.,rows(beta)+2]
									}
									else if (change1 < 5*tol) {
										if (max(abs(beta - store_iters[.,rows(beta)+2])) > .0005) {
											beta = store_iters[.,rows(beta)+2]
										}
									}
								}	
							}
						}
					}
					
					// reset acceleration loop
					store_iters = J(rows(beta), rows(beta)+2,.)
					accel_iter1  = accel_iter2 =  0 
				}
			}
			else {
				store_iters = J(rows(beta), rows(beta)+2,.)
				accel_iter1  = accel_iter2 =  0 
			}
		}
		
		last_change = change1
		
		change1 = editmissing( (beta_old1 - beta)'(beta_old1-beta) / (beta'beta), 0)

		iter1 = iter1 + 1	

		if ((change1 > .5) & (iter1 > accel_interval)) {
			beta = beta_old1
			change1 = last_change
		}
		
		//display results
		if (verb > 0) {
			kk = min((rows(beta),6))
			if ((mod(iter1,verb)==0) | iter1 == 1) {
				printf("iteration %f:	diff = %12.0g	", iter1, change1)
				printf("coeffs =")
				for (k = 1; k<=kk; k++) {
					printf(" %12.0g", beta[k,.])
				}
				printf("\n")
			}
		}
		
		// require 2 consecutive "hits" for convergence
		if (change1 > tol) {
			hits = 0
		}
		else {
			hits = hits + 1
		}
	//(beta', change1, iter1, max(sumX :/ sumXhat), max(Xtrend :/ Xhattrend))
	} while ((hits < 2) & (iter1 < max)) 
	
	st_numscalar(n_iter, iter1)
	st_numscalar(N_obs, rows(lhs[notmiss,.]))
	st_numscalar(N_dropped, rows(lhs) - rows(lhs[notmiss,.]))
	
	// apply normalizations - each country's largest D (lowest trade cost) normalized to 1, for both exports and imports
	if (which != 2) {
		D = colshape(D, NN_n)		
		for (t=1; t<=NN_y; t++) {
			for (i=1; i<=NN_i; i++) {
				long_index = ((t-1) * NN_i * NN_n + (i-1)*NN_n + 1, 1 \ (t-1) * NN_i* NN_n + (i-1)*NN_n + NN_n, 1)
				wide_index = ((t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n)
	
				Pi1[|long_index|] = Pi1[|long_index|] :/ rowmax(D[|wide_index|])
				D[|wide_index|] = D[|wide_index|] :/ rowmax(D[|wide_index|])
				
				P1[|long_index|] = P1[|long_index|] :/ colmax(D[|wide_index|])'
				D[|wide_index|] = D[|wide_index|] :/ colmax(D[|wide_index|])				
			}
		}
		D = colshape(D,1)
	}
	// Future: allow user to specify a numeraire country to normalize P's and Pi's
	
	// post results to Stata
	M[.,6]  = D[X_index,.]
	M[.,7]  = Pi1[Pi_index1,.]
	M[.,8]  = P1[P_index1,.]
	M[.,9]  = tt[X_index,.]
	
	st_store(., Y_w, touse, Yw[Pi_index1,.])
	st_store(., y_i, touse, y[Pi_index1,.])
	st_store(., e_j, touse, e[P_index1,.])	
	st_matrix(b, beta')
}
end


/*********************************************************************************/
/* EXPURGATE_FES  (modified from "EXPURG2EF", by Paulo Guimaraes. see: -poi2hdfe-) */
/*********************************************************************************/

// This code removes the influence of the excluded FEs on the variables of interest,
// in order to then compute the standard errors of the estimated betas.

// For three groups, solve for fixed effects {w1_it}, (w2_jt}, {w3_ij} s.t.

// sum_j { X_ijt * [`pvar'_ijt - w1_it - w2_jt - w3_ij]} = 0 for all i,t
// sum_i { X_ijt * [`pvar'_ijt - w1_it - w2_jt - w3_ij]} = 0 for all j,t 
// sum_t { X_ijt * [`pvar'_ijt - w1_it - w2_jt - w3_ij]} = 0 for all i,j 

// The solution then yields a set of residuals for `pvar', 

// r_ijt = sqrt(X_ijt)*[`pvar'_ijt - w1_it - w2_jt - w3_ij],

// which are then used above to compute standard errors for each `pvar'.

// For a reference, see Figueiredo, Guimaraes, and Woodward JUE (2015): 
// "Industry location, distance decay, and knowledge spillovers: Following the patent paper trail"

mata:
void expurgate_fes(string scalar policyvar, string scalar mata_varlist, string scalar branch,| string scalar touse)
{
	st_view(M, ., tokens(mata_varlist),touse)
	st_view(PV, ., tokens(policyvar),touse)
	
	which = st_numscalar(branch)
	
	ind_id = M[.,1]     // industry id, year id, exporter and importer ids.
	yr_id  = M[.,2]   
	exp_id = M[.,3]   
	imp_id = M[.,4]   
		
	NN_i  = max(ind_id)   // total #s of included industries, years, and countries, for use in loops
	NN_y  = max(yr_id)
	NN_n = max((max(exp_id), max(imp_id)))
	
	
	//sort and set up matrix structure, as in sg_panel_iter
 	X_index = ( (yr_id:-1) :* NN_i :* NN_n^2 :+ (ind_id:-1) * NN_n^2 :+ (exp_id:-1):* NN_n :+ imp_id)
	
	BIG_N = NN_y*NN_i*NN_n*NN_n
	
	pvar=Xhat=timevar=J(BIG_N,1,0) 
	
	pvar[X_index,1]       = PV
		
	Xhat[X_index,1]       = M[.,5] // the conditional mean of the original dependent variable, "X_ij_hat", used here as a weighting parameter
	timevar[X_index,1]    = M[.,6] // time intervals for use with trends
	
	if (which == 3 | which == 4) {
		time = uniqrows(timevar)       // simple time vector, with one entry per year, sorted from first to last
	}
	else {
		time = J(NN_y,1,1)
	}
	
	sqrt_Xhat = sqrt(Xhat)
	
	Xhat    = colshape(Xhat,NN_n)
	timevar = colshape(timevar,NN_n)
	pvar    = colshape(pvar,NN_n)


	// construct sumxh1, sumxh2, sumxh3, sumxh4: these terms contain sums of Xhat across the different groups
	sumxh1=sumxh2=sumxh3=sumxh4=J(NN_y*NN_i*NN_n,NN_n,0)
	for (t=1; t<=NN_y; t++) {
		for (i=1; i <= NN_i; i++) {
			Xhat_kt  = editmissing(Xhat[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|],0)  // this is a single NxN matrix for fitted trade flows in industry k at time t. 
		
			sumxh1[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|] = rowsum(Xhat_kt)#J(1,NN_n,1)
			
			sumxh2[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|] = colsum(Xhat_kt)#J(NN_n,1,1)
		
			if (which == 0 | which == 3) {
				sumxh3[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				sumxh3[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				Xhat_kt
			}
			else if (which == 1 | which == 4) {      //which = 1 or 4: pair fixed effects are symmetric
				sumxh3[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
				sumxh3[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
				Xhat_kt+
				Xhat_kt'
			}
			if (which == 3) {						 //which = 3 or 4: include linear time trends
					sumxh4[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
					sumxh4[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
					time[t]^2*Xhat_kt              	 // The "^2" comes from the OLS f.o.c. for a time trend regressor
			}
			if (which == 4) {
					sumxh4[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] = 
					sumxh4[|(i-1)* NN_n + 1, 1 \ (i-1) * NN_n +NN_n,NN_n|] +
					time[t]^2*Xhat_kt+
					time[t]^2*Xhat_kt'
			}
		}
	}
	sumxh3 = J(NN_y,1,1)#sumxh3[|1, 1 \ NN_i * NN_n, NN_n|]   // distributes sums over time across each year
	sumxh4 = J(NN_y,1,1)#sumxh4[|1, 1 \ NN_i * NN_n, NN_n|]  
	
	
	// iterate on w1, w2, w3, w4 until convergence
	w1=w2=w3=w4  =  J(NN_y*NN_i*NN_n,NN_n,0)                  // These will eventually contain the solutions for the fixed effect and time trend terms
	j=0
	res1=res2 = J(BIG_N,1,1)
	do {
		sumpx1=sumpx2=sumpx3=sumpx4 =  J(NN_y*NN_i*NN_n,NN_n,0)   // Each sumpx nets out 1 set of FEs/trends from pvar at a time and weights by Xhat
		res1 = sqrt_Xhat :* colshape(pvar - w1 - w2 - w3 - w4:*timevar,1)	
		
		rhs1  = pvar - w2 - w3 - (timevar:*w4)	
		sumpx1 = rowsum(editmissing(Xhat:*rhs1,0))#J(1,NN_n,1)
		w1 = sumpx1 :/ sumxh1
		
		for (t=1; t<=NN_y; t++) {
			for (i=1; i <= NN_i; i++) {
				Xhat_kt  =  Xhat[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|]

				rhs2  = pvar[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|] -
						w1[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|] -
						w3[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|] -
						time[t]*w4[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|] 
						
				sumpx2[|(t-1) * NN_i * NN_n +(i-1)*NN_n + 1, 1 \ (t-1) * NN_i * NN_n +(i-1)*NN_n +NN_n,NN_n|] = colsum(editmissing(Xhat_kt:*rhs2,0))#J(NN_n,1,1) 
			}
		}
		w2 = sumpx2 :/ sumxh2
		
		if (which != 2) {
			for (t=1; t<=NN_y; t++) {
				Xhat_t  =  Xhat[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|] // X_t stacks each X_kt (as defined above) grids by industry for each period t
				
				rhs3  = pvar[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|] -
						w1[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|] -
						w2[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|] -
						time[t]*w4[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|]
						
				if (which == 0 | which == 3) {
					sumpx3[|1, 1 \ NN_i * NN_n,NN_n|] = 
					sumpx3[|1, 1 \ NN_i * NN_n,NN_n|] +
					editmissing(Xhat_t:*rhs3,0)
				}
				else if (which == 1 | which == 4) {      //which = 1 or 4: pair fixed effects are symmetric
					sumpx3[|1, 1 \ NN_i * NN_n,NN_n|] = 
					sumpx3[|1, 1 \ NN_i * NN_n,NN_n|] +
					editmissing(Xhat_t:*rhs3,0)+
					editmissing(Xhat_t:*rhs3,0)'
				}
			}
			sumpx3 = J(NN_y,1,1)#sumpx3[|1, 1 \ NN_i * NN_n, NN_n|]
			w3 = sumpx3 :/ sumxh3
		}
		
		if (which == 3 | which == 4) {   //which = 3 or 4: include linear time trends
			for (t=1; t<=NN_y; t++) {
				Xhat_t  =  Xhat[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|]  // X_t stacks each X_kt (as defined above) grids by industry for each period t
				
				rhs4  = pvar[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|] -
						w1[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|] -
						w2[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|] -
						w3[|(t-1) * NN_i * NN_n+ 1, 1 \ t * NN_i * NN_n,NN_n|]
				
				if (which == 3) {
					sumpx4[|1, 1 \ NN_i * NN_n,NN_n|] = 
					sumpx4[|1, 1 \ NN_i * NN_n,NN_n|] +
					time[t]*editmissing(Xhat_t:*rhs4,0)
				}
				else if (which == 4) {      //which = 1 or 4: pair fixed effects are symmetric
					sumpx4[|1, 1 \ NN_i * NN_n,NN_n|] = 
					sumpx4[|1, 1 \ NN_i * NN_n,NN_n|] +
					time[t]*editmissing(Xhat_t:*rhs4,0)+
					time[t]*editmissing(Xhat_t:*rhs4,0)'
				}
			}
			sumpx4 = J(NN_y,1,1)#sumpx4[|1, 1 \ NN_i * NN_n, NN_n|]
			w4 = sumpx4 :/ sumxh4
		}	
		res2 = sqrt_Xhat :* colshape(pvar - w1 - w2 - w3 - w4:*timevar,1)	
		dif  = mean(reldif(res2,res1))
		j=j+1
	} while (abs(dif)>1e-9)
	st_store(., "_res", touse, res2[X_index,1])	
}
end

mata:
real vector selectidx(real vector x, real scalar vers)
{
	if (vers >= 13) {
		return(selectidx13(x))
	}
	else {
		return(selectidx11(x))
	}
}
end


mata:
real vector selectidx13(real vector x)
{
    return(selectindex(x))
}
end

// This workaround for selectindex originally created by Hua Peng
// http://www.statalist.org/forums/forum/general-stata-discussion/general/1305770-outreg-error
mata:
real vector selectidx11(real vector x)
{
    real scalar row, cnt, i
    vector res
	
    row = rows(x)
    
    cnt = 1
    res = J(1, row, 0)
    for(i=1; i<=row; i++) {
        if(x[i] != 0) {
            res[cnt] = i ;
            cnt++ ;
        }
    }
    
    if(cnt>1) {
        res = res[1, 1..cnt-1]
    }
    else {
        res = J(1, 0, 0)
    }
    
    if(row>1) {
        res = res'
    }
    
    return(res)
}

end